#!/usr/bin/env bash
###~ description: Rename a agent in Asterisk
if [[ -z "$1" ]]; then
    echo "User ID is not defined..."
    exit 1
else
    EXTEN=$1
fi

if [[ -z "$2" ]]; then
    echo "Username is not defined..."
    exit 1
else 
     NAME="$2"
fi

OLD_NAME="$(mysql -e "SELECT label FROM asterisk.fop2buttons WHERE exten = $EXTEN;" | sed '1d')"

echo "EXTEN: $EXTEN"
echo "NAME: $NAME"
echo "OLD_NAME: $OLD_NAME"

echo "---------------------------------------"
echo " Current State"
echo "---------------------------------------"
asterisk -rx "database get AMPUSER/$EXTEN cidname"
mysql -e "SELECT data FROM asterisk.sip WHERE id = $EXTEN AND keyword = 'callerid';"
mysql -e "SELECT name FROM asterisk.users WHERE extension = $EXTEN;"
mysql -e "SELECT label, queuechannel FROM asterisk.fop2buttons WHERE exten = $EXTEN;"
mysql -e "SELECT name, queue FROM qstats.monofon_agent WHERE extension = $EXTEN AND date = CURDATE();"
asterisk -rx "queue show" | grep "Local/$EXTEN@"
echo "---------------------------------------"
echo "Press Enter to continue..."
read -r

asterisk -rx "database get AMPUSER/$EXTEN cidname"
asterisk -rx "database put AMPUSER/$EXTEN cidname \"$NAME\""

mysql -e "SELECT data FROM asterisk.sip WHERE id = $EXTEN AND keyword = 'callerid';"
mysql -e "UPDATE asterisk.sip SET data = '$NAME <$EXTEN>' WHERE id = $EXTEN AND keyword = 'callerid';"

mysql -e "SELECT name FROM asterisk.users WHERE extension = $EXTEN;"
mysql -e "UPDATE asterisk.users SET name = '$NAME' WHERE extension = $EXTEN;"

mysql -e "SELECT label, queuechannel FROM asterisk.fop2buttons WHERE exten = $EXTEN;"
mysql -e "UPDATE asterisk.fop2buttons SET queuechannel = REPLACE(queuechannel, '$OLD_NAME', '$NAME') WHERE exten = $EXTEN;"
mysql -e "UPDATE asterisk.fop2buttons SET label = '$NAME' WHERE exten = $EXTEN;"
mysql -e "UPDATE qstats.monofon_agent SET name = '$NAME' WHERE extension = $EXTEN AND date = CURDATE();"

/usr/local/fop2/autoconfig-buttons.sh
/usr/local/fop2/autoconfig-users.sh
/etc/init.d/fop2 reload

if [[ -n "$(which fwconsole)" ]]; then
        fwconsole reload
else
        amportal a r
fi

mapfile -t queue_list < <(asterisk -rx "queue show" | grep strategy | awk '{print $1}') 
for queue in "${queue_list[@]}"; do
        member=$(asterisk -rx "queue show $queue" | grep "Local/$EXTEN@" | perl -ne '/\((\S+)/ && print "$1\n"')
        state_interface=$(asterisk -rx "queue show $queue" | grep "Local/$EXTEN@" | perl -ne '/from (\S+)\)/ && print "$1\n"')
        if [[ -n "$member" ]]; then
                echo "User $EXTEN is in queue $queue"
                asterisk -rx "queue remove member $member from $queue"
                asterisk -rx "queue add member $member to $queue penalty 0 as \"$NAME\" state_interface $state_interface"
        else
                echo "User $EXTEN is not in queue $queue, skipping..."
        fi
done

echo "---------------------------------------"
echo " Final State"
echo "---------------------------------------"
asterisk -rx "database get AMPUSER/$EXTEN cidname"
mysql -e "SELECT data FROM asterisk.sip WHERE id = $EXTEN AND keyword = 'callerid';"
mysql -e "SELECT name FROM asterisk.users WHERE extension = $EXTEN;"
mysql -e "SELECT label, queuechannel FROM asterisk.fop2buttons WHERE exten = $EXTEN;"
mysql -e "SELECT name, queue FROM qstats.monofon_agent WHERE extension = $EXTEN AND date = CURDATE();"
echo "---------------------------------------"
