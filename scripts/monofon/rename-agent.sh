#!/usr/bin/env bash
###~ description: Rename a agent in Asterisk

set -uo pipefail

# --- arguments ---------------------------------------------------------------

if [[ -z "${1:-}" ]] || [[ "$1" == --* ]]; then
    echo "User ID is not defined..."
    exit 1
else
    EXTEN=$1
fi

if [[ ! "$EXTEN" =~ ^[0-9]{1,10}$ ]]; then
    echo "ERROR: extension must be numeric: '$EXTEN'"
    exit 1
fi

if [[ -z "${2:-}" ]] || [[ "$2" == --* ]]; then
    echo "Username is not defined..."
    exit 1
else
    NAME="$2"
fi

NO_PROMPT=false
FROM_EXTEN=""
shift 2
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-prompt)
            NO_PROMPT=true
            shift
            ;;
        --from)
            if [[ -z "${2:-}" ]] || [[ "$2" == --* ]]; then
                echo "--from requires an extension number"
                exit 1
            fi
            FROM_EXTEN="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1"
            exit 1
            ;;
    esac
done

if [[ -n "$FROM_EXTEN" ]] && [[ ! "$FROM_EXTEN" =~ ^[0-9]{1,10}$ ]]; then
    echo "ERROR: --from must be numeric: '$FROM_EXTEN'"
    exit 1
fi

# --- helpers -----------------------------------------------------------------

# Escape for a single-quoted MySQL string: backslash first, then quote
sql_quote() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\'/\\\'}"
    printf '%s' "$s"
}

mysql_run() {
    if ! mysql --batch --raw -e "$1"; then
        echo "ERROR: mysql command failed"
        return 1
    fi
}

astdb_get() {
    asterisk -rx "database get AMPUSER/$1 cidname" 2>/dev/null \
        | sed -n 's/^Value: //p' | head -1
}

NAME_SQL="$(sql_quote "$NAME")"

# --- find the previous extension ---------------------------------------------

if [[ -z "$FROM_EXTEN" ]]; then
    mapfile -t FROM_CANDIDATES < <(
        mysql -Nse "SELECT extension FROM asterisk.users
                    WHERE TRIM(name) = '$NAME_SQL' AND extension != $EXTEN;"
    )
    case ${#FROM_CANDIDATES[@]} in
        0)
            echo "No prior extension found for '$NAME' — treating as new assignment."
            ;;
        1)
            FROM_EXTEN="${FROM_CANDIDATES[0]}"
            echo "Detected move: '$NAME' is currently on $FROM_EXTEN, will vacate after rename."
            ;;
        *)
            echo "ERROR: '$NAME' is assigned to multiple extensions: ${FROM_CANDIDATES[*]}"
            echo "Resolve manually or specify --from <ext> to disambiguate."
            exit 1
            ;;
    esac
fi

OLD_NAME="$(mysql -Nse "SELECT label FROM asterisk.fop2buttons WHERE exten = $EXTEN;")"
OLD_NAME_SQL="$(sql_quote "$OLD_NAME")"

echo "EXTEN: $EXTEN"
echo "NAME: $NAME"
echo "OLD_NAME: $OLD_NAME"
[[ -n "$FROM_EXTEN" ]] && echo "FROM_EXTEN: $FROM_EXTEN (will be vacated)"

print_state() {
    local ext="$1"
    asterisk -rx "database get AMPUSER/$ext cidname"
    mysql -e "SELECT data FROM asterisk.sip WHERE id = $ext AND keyword = 'callerid';"
    mysql -e "SELECT name FROM asterisk.users WHERE extension = $ext;"
    mysql -e "SELECT label, queuechannel FROM asterisk.fop2buttons WHERE exten = $ext;"
    mysql -e "SELECT name, queue FROM qstats.monofon_agent WHERE extension = $ext AND date = CURDATE();"
    asterisk -rx "queue show" | grep "Local/$ext@"
}

echo "---------------------------------------"
echo " Current State (target: $EXTEN)"
echo "---------------------------------------"
print_state "$EXTEN"
if [[ -n "$FROM_EXTEN" ]]; then
    echo "---------------------------------------"
    echo " Current State (vacating: $FROM_EXTEN)"
    echo "---------------------------------------"
    print_state "$FROM_EXTEN"
fi
echo "---------------------------------------"

if [[ "$NO_PROMPT" != "true" ]]; then
    echo "Press Enter to continue..."
    read -r
fi

# --- write -------------------------------------------------------------------
# asterisk.sip, asterisk.users and asterisk.fop2buttons are MyISAM, so there is
# no transaction to wrap these writes in: a failure part way through leaves the
# records inconsistent and cannot be rolled back. The statements therefore run
# on a single connection and the result is read back and verified below.

SQL="UPDATE asterisk.sip   SET data = '$NAME_SQL <$EXTEN>' WHERE id = $EXTEN AND keyword = 'callerid';
UPDATE asterisk.users SET name = '$NAME_SQL' WHERE extension = $EXTEN;
UPDATE asterisk.fop2buttons SET label = '$NAME_SQL' WHERE exten = $EXTEN;
UPDATE qstats.monofon_agent SET name = '$NAME_SQL' WHERE extension = $EXTEN AND date = CURDATE();"

# With an empty OLD_NAME, REPLACE would inject the name at every "MemberName="
if [[ -n "$OLD_NAME" ]]; then
    SQL+="
UPDATE asterisk.fop2buttons
   SET queuechannel = REPLACE(queuechannel, 'MemberName=$OLD_NAME_SQL', 'MemberName=$NAME_SQL')
 WHERE exten = $EXTEN;"
else
    echo "NOTE: fop2buttons.label empty for $EXTEN, skipping queuechannel rewrite."
fi

if ! mysql_run "$SQL"; then
    echo "ERROR: database update failed for $EXTEN, aborting before AstDB write."
    exit 1
fi

asterisk -rx "database put AMPUSER/$EXTEN cidname \"$NAME\"" > /dev/null

# --- vacate the previous extension -------------------------------------------

if [[ -n "$FROM_EXTEN" ]]; then
    FROM_OLD_LABEL="$(mysql -Nse "SELECT label FROM asterisk.fop2buttons WHERE exten = $FROM_EXTEN;")"
    FROM_OLD_LABEL_SQL="$(sql_quote "$FROM_OLD_LABEL")"
    PLACEHOLDER="$FROM_EXTEN"

    FROM_SQL="UPDATE asterisk.sip   SET data = '$PLACEHOLDER <$FROM_EXTEN>' WHERE id = $FROM_EXTEN AND keyword = 'callerid';
UPDATE asterisk.users SET name = '$PLACEHOLDER' WHERE extension = $FROM_EXTEN;
UPDATE asterisk.fop2buttons SET label = '$PLACEHOLDER' WHERE exten = $FROM_EXTEN;"

    if [[ -n "$FROM_OLD_LABEL" ]]; then
        FROM_SQL+="
UPDATE asterisk.fop2buttons
   SET queuechannel = REPLACE(queuechannel, 'MemberName=$FROM_OLD_LABEL_SQL', 'MemberName=$PLACEHOLDER')
 WHERE exten = $FROM_EXTEN;"
    fi

    if ! mysql_run "$FROM_SQL"; then
        echo "ERROR: database update failed while vacating $FROM_EXTEN."
        exit 1
    fi

    asterisk -rx "database put AMPUSER/$FROM_EXTEN cidname \"$PLACEHOLDER\"" > /dev/null
fi

# --- verification ------------------------------------------------------------

VERIFY_FAILED=0

verify_ext() {
    local ext="$1" expected="$2" label="$3"
    local sip users fop astdb

    sip="$(mysql -Nse "SELECT TRIM(SUBSTRING_INDEX(data, '<', 1)) FROM asterisk.sip
                        WHERE id = $ext AND keyword = 'callerid';")"
    users="$(mysql -Nse "SELECT TRIM(name) FROM asterisk.users WHERE extension = $ext;")"
    fop="$(mysql -Nse "SELECT TRIM(label) FROM asterisk.fop2buttons WHERE exten = $ext;")"
    astdb="$(astdb_get "$ext")"

    echo "  $label ($ext) expecting '$expected'"
    for pair in "sip.callerid=$sip" "users.name=$users" "fop2buttons.label=$fop" "AstDB.cidname=$astdb"; do
        local field="${pair%%=*}" value="${pair#*=}"
        if [[ "$value" == "$expected" ]]; then
            echo "    OK   $field"
        else
            echo "    FAIL $field = '$value'"
            VERIFY_FAILED=1
        fi
    done
}

echo "---------------------------------------"
echo " Verification"
echo "---------------------------------------"
verify_ext "$EXTEN" "$NAME" "target"
if [[ -n "$FROM_EXTEN" ]]; then
    verify_ext "$FROM_EXTEN" "$FROM_EXTEN" "vacated"
fi

# --- FOP2 --------------------------------------------------------------------

echo -n "Running FOP2 autoconfig-buttons... "
if /usr/local/fop2/autoconfig-buttons.sh &> /dev/null; then
    echo "Done."
else
    echo "FAILED (exit $?)"
    VERIFY_FAILED=1
fi

if [[ "$VERIFY_FAILED" -ne 0 ]]; then
    echo
    echo "ERROR: rename did not fully apply. The records above marked FAIL are"
    echo "inconsistent; temsilci_isim_takip may miss this transition. Re-run this"
    echo "script or fix the listed fields manually."
    exit 1
fi

echo "Rename verified."
