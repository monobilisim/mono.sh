#!/bin/bash
###~ description: This script is used to manage WordOps

#~ variables
script_version="3.1.1"
if [[ "$CRON_MODE" == "1" ]]; then
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

    color_red=""
    color_green=""
    color_yellow=""
    color_blue=""
    color_reset=""

    #~ log file prefix
    echo "=== ( $(date) - $HOSTNAME ) =========================================" >/tmp/wordops-manager.log

    #~ redirect all outputs to file
    exec &>>/tmp/wordops-manager.log
else
    color_red=$(tput setaf 1)
    color_green=$(tput setaf 2)
    color_yellow=$(tput setaf 3)
    color_blue=$(tput setaf 4)
    color_reset=$(tput sgr0)
fi

#~ functions

function containsElement() {
    local e match="$1"
    shift
    for e; do [[ "$e" == "$match" ]] && return 0; done
    return 1
}

#~ backup site
backup_site() {
    [[ "$1" == "all" ]] && {
        local site_list=($(wo site list | ansi2txt | sort))
        echo "$color_yellow [ INFO ] Backing up all sites..."
    } || { local site_list=("$1"); }
    for site in "${site_list[@]}"; do
        [[ -n "${EXCLUDE_SITES}" && "${EXCLUDE_SITES}" =~ "${a}" ]] && {
            echo "$color_yellow [ SKIP ] Skipping \"$site\"..."
            continue
        }
        local tmpdir=$(mktemp -d)
        mkdir "$tmpdir/$site" && cd "$tmpdir/$site" || {
            echo "$color_red [ FAIL ] Failed to create temporary directory for \"$site\""
            return 1
        }

        local site_type=$(wo site info $site | grep 'Nginx configuration' | awk '{print $3}')
        local site_path=/var/www/$site
        [[ ! -d $site_path ]] && {
            echo "$color_red [ FAIL ] Site \"$site\" not found at $site_path"
            return 1
        }

        if [[ "$site_type" == "wp" ]]; then
            if [[ -e $site_path/htdocs/wp-config.php ]]; then
                local wp_config_file=$site_path/htdocs/wp-config.php
            elif [[ -e $site_path/wp-config.php ]]; then
                local wp_config_file=$site_path/wp-config.php
            fi
            local wp_version_file=$site_path/htdocs/wp-includes/version.php
            local wp_content_dir=$site_path/htdocs/wp-content

            [[ ! -e $wp_config_file ]] && {
                echo "$color_red [ FAIL ] wp-config.php not found for \"$site\""
                return 1
            }

            echo "$color_blue [ INFO ] Taking backup of existing site for \"$site\"..."
            wp --allow-root --path=/var/www/$site/htdocs db export $site.sql &>/dev/null && echo "$color_green [  OK  ] Database backup exported successfully in $site_path/htdocs/$site.sql..." || {
                echo "$color_red [ FAIL ] Failed to export database backup..."
                return 1
            }

            cp -a $wp_version_file $wp_config_file $wp_content_dir .
            echo "$color_green [  OK  ] Backup of existing site taken successfully..."
            echo "$color_blue [ INFO ] Writing collected site information to siteinfo.txt..."
            echo "wo_site_name=$site" >siteinfo.txt
            echo "wo_site_type=$site_type" >>siteinfo.txt
            echo "wo_site_root=\$wo_site_name/wp-content" >>siteinfo.txt
            echo "wo_site_config=\$wo_site_name/wp-config.php" >>siteinfo.txt
            echo "wo_site_db_file=\$wo_site_name/\$wo_site_name.sql" >>siteinfo.txt
            echo "wo_site_project_name=$project_name" >>siteinfo.txt
            cd ..
        elif [[ "$site_type" == "mysql" ]]; then
            local db_name=$(wo site info $site | grep 'DB_NAME' | awk '{print $2}')
            local db_user=$(wo site info $site | grep 'DB_USER' | awk '{print $2}')
            local db_pass=$(wo site info $site | grep 'DB_PASS' | awk '{print $2}')

            echo "$color_blue [ INFO ] Taking backup of existing site for \"$site\"..."
            cp -a $site_path/htdocs .
            mysqldump $db_name -h localhost -u $db_user -p$db_pass >$site.sql && echo "$color_green [  OK  ] Database backup exported successfully..." || {
                echo "$color_red [ FAIL ] Failed to export database backup..."
                return 1
            }
            echo "$color_green [  OK  ] Backup of existing site taken successfully..."
            echo "$color_blue [ INFO ] Writing collected site information to siteinfo.txt..."
            echo "wo_site_name=$site" >siteinfo.txt
            echo "wo_site_type=$site_type" >>siteinfo.txt
            echo "wo_site_root=\$wo_site_name/htdocs" >>siteinfo.txt
            echo "wo_site_db_file=\$wo_site_name/\$wo_site_name.sql" >>siteinfo.txt
            echo "wo_site_project_name=$project_name" >>siteinfo.txt
            cd ..
        elif [[ "$site_type" =~ "php" || "$site_type" == "html" ]]; then
            echo "$color_blue [ INFO ] Taking backup of existing site for \"$site\"..."
            cp -a $site_path/htdocs .
            echo "$color_green [  OK  ] Backup of existing site taken successfully..."
            echo "$color_blue [ INFO ] Writing collected site information to siteinfo.txt..."
            echo "wo_site_name=$site" >siteinfo.txt
            echo "wo_site_type=$site_type" >>siteinfo.txt
            echo "wo_site_root=\$wo_site_name/htdocs" >>siteinfo.txt
            echo "wo_site_project_name=$project_name" >>siteinfo.txt
            cd ..
        fi

        echo "$color_blue [ INFO ] Compressing backup files..."
        tar -czf "$site-$(date +%A).tar.gz" "$site" && echo "$color_green [  OK  ] Daily backup compressed successfully..." || {
            echo "$color_red [ FAIL ] Failed to compress daily backup..."
            return 1
        }
        if [[ "$NO_UPLOAD" == "1" ]]; then
            cp "$site-$(date +%A).tar.gz" /root/ && echo "$color_yellow [ INFO ] Defined NO_UPLOAD variable, backup copied to /root/" || {
                echo "$color_red [ FAIL ] Failed to copy daily backup to /root/..."
                return 1
            }
        else
            mc cp "./$site-$(date +%A).tar.gz" "$MINIO_PATH/$HOSTNAME/$site/" &>/dev/null && echo "$color_green [  OK  ] Daily backup uploaded to MinIO successfully..." || {
                echo "$color_red [ FAIL ] Failed to upload daily backup to MinIO..."
                return 1
            }
        fi

        if [[ $(date -d "yesterday" +%m) != $(date +%m) ]]; then
            echo "$color_blue [ INFO ] Monthly backup detected, taking monthly backup..."
            mv "$site-$(date +%A).tar.gz" "$site-$(date -I).tar.gz"
            if [[ "$NO_UPLOAD" != "1" ]]; then
                mc cp "./$site-$(date -I).tar.gz" "$MINIO_PATH/$HOSTNAME/$site/" &>/dev/null && echo "$color_green [  OK  ] Monthly backup uploaded to MinIO successfully..." || {
                    echo "$color_red [ FAIL ] Failed to upload monthly backup to MinIO..."
                    return 1
                }
            fi
        fi

        echo -e "$color_green [  OK  ] Backup process completed successfully for \"$site\", cleaning up...\n$color_reset"
        cd /tmp
        rm -rf $tmpdir
    done

}

#~ backup status
backup_status() {
    local local_sites=($(list_mode=raw list_from=local list_backups))
    for site in ${local_sites[@]}; do
        local today=$(date +%Y-%m-%d)
        local remote_status=$(mc ls $MINIO_PATH/$HOSTNAME/$site | grep -Po '(?<=^\[)([0-9]{4}-[0-9]{2}-[0-9]{2})' | sort | tail -n 1)
        [[ -z $remote_status ]] && {
            echo -e "$color_yellow [ INFO ] No backup found for \"$site\" on MinIO..."
            continue
        }

        if [[ "$remote_status" == "$today" ]]; then
            echo -e "$color_green [  OK  ] Backup for \"$site\" on MinIO is up to date."
        else
            echo -e "$color_yellow [ INFO ] Backup for \"$site\" on MinIO is outdated. Last backup was on ${remote_status}."
        fi
    done
}

#~ check configuration file
check_config() {
    [[ ! -e $@ ]] && {
        echo -e "$color_red [ FAIL ] File \"$@\" not found, aborting..."
        exit 1
    }
    . "$@"

    local vars=(ALARM_WEBHOOK_URL MINIO_PATH UPTIME_KUMA_API_URL)
    for var in "${vars[@]}"; do
        [[ -z ${!var} ]] && {
            echo -e "$color_red [ FAIL ] Variable \"$var\" not defined, aborting..."
            return 1
        }
    done
    return 0
}

#~ check crontab
check_crontab() {
    [[ "$(id -u)" != "0" ]] && {
        echo -e "$color_red [ FAIL ] This script must be run as root, aborting..."
        return 1
    }
    CRONCONFIG=$(crontab -u root -l | grep $(realpath "$0") | grep '^00 00')

    if [[ ! -n $CRONCONFIG ]]; then
        echo -e "$color_red [ FAIL ] Cron is not configured correctly, please add this line in crontab: 00 00 * * * $(realpath "$0") -b all"
        return 1
    else
        echo -e "$color_green [  OK  ] Cron is configured correctly..."
        return 0
    fi
}

check_database() {
    mysql -u wordops -pwordops -e "use wordops" &>/dev/null
    if [[ $? -ne 0 ]]; then
        echo "$color_yellow [ INFO ] Fact database is not initialized, initializing..."
        echo "$color_blue [ INFO ] Creating fact database..."
        mysql -e "CREATE DATABASE IF NOT EXISTS wordops;" &>/dev/null && echo "$color_green [  OK  ] Fact database created successfully..." || {
            echo "$color_red [ FAIL ] Failed to create fact database..."
            return 1
        }

        echo "$color_blue [ INFO ] Creating user..."
        mysql -e "CREATE USER 'wordops'@'localhost' IDENTIFIED BY 'wordops';" &>/dev/null && echo "$color_green [  OK  ] User created successfully..." || {
            echo "$color_red [ FAIL ] Failed to create user..."
            return 1
        }

        echo "$color_blue [ INFO ] Granting privileges..."
        mysql -e "GRANT ALL PRIVILEGES ON wordops.* TO 'wordops'@'localhost';" &>/dev/null && echo "$color_green [  OK  ] Privileges granted successfully..." || {
            echo "$color_red [ FAIL ] Failed to grant privileges..."
            return 1
        }

        echo "$color_blue [ INFO ] Creating fact table..."
        mysql wordops -u wordops -pwordops -e "CREATE TABLE IF NOT EXISTS wordops_facts (id INT AUTO_INCREMENT PRIMARY KEY, web_url VARCHAR(100) NOT NULL UNIQUE, site_type VARCHAR(15) NOT NULL, php_version VARCHAR(10), cf_proxy BOOLEAN DEFAULT FALSE, nginx_helper BOOLEAN DEFAULT FALSE, wp_redis BOOLEAN DEFAULT FALSE, wp_admin_url VARCHAR(100), wp_admin_username VARCHAR(50), wp_admin_password VARCHAR(100), sftp_user VARCHAR(100) NOT NULL, sftp_pass VARCHAR(50) NOT NULL, project_name VARCHAR(100));" &>/dev/null && echo "$color_green [  OK  ] Fact table created successfully..." || {
            echo "$color_red [ FAIL ] Failed to create fact table..."
            return 1
        }
        mysql wordops -u wordops -pwordops -e "CREATE TABLE IF NOT EXISTS wordops_stats (id INT AUTO_INCREMENT PRIMARY KEY, server_name VARCHAR(100) NOT NULL, last_update TIMESTAMP DEFAULT CURRENT_TIMESTAMP);" &>/dev/null && echo "$color_green [  OK  ] Stats table created successfully..." || {
            echo "$color_red [ FAIL ] Failed to create stats table..."
            return 1
        }
        mysql wordops -u wordops -pwordops -e "INSERT INTO wordops_stats (server_name, last_update) VALUES ('$HOSTNAME', CURRENT_TIMESTAMP);" &>/dev/null && echo "$color_green [  OK  ] Stats table updated successfully..." || {
            echo "$color_red [ FAIL ] Failed to update stats table..."
            return 1
        }
    else
        echo "$color_green [  OK  ] Fact database is already initialized..."
    fi
}

#~ database manager
database_manager() {
    #~ insert: $1=mode, $2=values
    #~ update: $1=mode, $2=column, $3=value, $4=web_url
    #~ delete: $1=mode, $2=web_url
    case $1 in
    "insert")
        local site_name=$(echo $2 | cut -d '"' -f2)
        mysql wordops -u wordops -pwordops -e "INSERT INTO wordops_facts (web_url, site_type, php_version, cf_proxy, nginx_helper, wp_redis, wp_admin_url, wp_admin_username, wp_admin_password, sftp_user, sftp_pass, project_name) VALUES ($2);" &>/dev/null && echo -e "$color_green [  OK  ] Inserted successfully for $site_name..." || {
            echo -e "$color_red [ FAIL ] Failed to insert for $site_name..."
            return 1
        }
        ;;
    "update")
        mysql wordops -u wordops -pwordops -e "UPDATE wordops_facts SET $2=$3 WHERE web_url=$4;" &>/dev/null && echo -e "$color_green [  OK  ] Updated successfully for $4..." || {
            echo -e "$color_red [ FAIL ] Failed to update for $4..."
            return 1
        }
        ;;
    "delete")
        mysql wordops -u wordops -pwordops -e "DELETE FROM wordops_facts WHERE web_url=$2;" &>/dev/null && echo -e "$color_green [  OK  ] Deleted successfully for $2..." || {
            echo -e "$color_red [ FAIL ] Failed to delete for $2..."
            return 1
        }
        ;;
    esac
    mysql wordops -u wordops -pwordops -e "UPDATE wordops_stats SET last_update=CURRENT_TIMESTAMP WHERE server_name='"$HOSTNAME"';" &>/dev/null && echo -e "$color_green [  OK  ] Updated successfully for $HOSTNAME..." || {
        echo -e "$color_red [ FAIL ] Failed to update for $HOSTNAME..."
        return 1
    }

}

#~ download backup from MinIO
download_backup() {
    list_mode=nonraw list_from=remote list_title="[remote] Select site for restore process ($HOSTNAME)" list_backups
    printf "> "
    read site_name
    [[ -z $site_name ]] && {
        echo -e "$color_red [ FAIL ] Invalid site name, aborting..."
        return 1
    }
    printf "\n"

    list_mode=nonraw list_from=remote list_title="[remote] Select backup for restore process ($site_name) ($HOSTNAME)" site_name=$site_name list_backups
    printf "%s" "$site_name> "
    read backup_file_name
    [[ -z $backup_file_name ]] && {
        echo -e "$color_red [ FAIL ] Invalid backup file name, aborting..."
        return 1
    }

    mc cp $MINIO_PATH/$HOSTNAME/$site_name/$backup_file_name $HOME/
    [[ $? -eq 0 ]] && echo -e "$color_green [  OK  ] Backup downloaded successfully in $HOME/$backup_file_name" || echo -e "$color_red [ FAIL ] Failed to download backup..."
}

#~ get site facts
get_facts() {
    [[ -n "$1" ]] && { local site_list=("$1"); } || { local site_list=($(wo site list | ansi2txt)); }
    local json='['
    for site in ${site_list[@]}; do
        local site_name=$site

        local site_type=$(wo site info $site | grep 'Nginx configuration' | awk '{print $3}')
        if [[ "$site_type" == "wp" ]]; then
            site_type="WordPress"
        elif [[ "$site_type" == "mysql" ]]; then
            site_type="PHP + MySQL"
        elif [[ "$site_type" =~ "php" ]]; then
            site_type="PHP"
        elif [[ "$site_type" == "html" ]]; then
            site_type="Static"
        else
            site_type="Unknown"
        fi

        local php_version=$(wo site info $site | grep 'PHP Version' | awk '{print $3}')

        [[ "$(curl -LIs $site | grep Server | cut -d ' ' -f2 | tr -dc [[:alnum:]])" == "cloudflare" ]] && local site_cfproxy="1" || local site_cfproxy="0"

        if [[ "$site_type" == "WordPress" ]]; then
            [[ "$(wp --allow-root --path=/var/www/$site/htdocs plugin list | grep -i nginx-helper | awk '{print $2}')" == "active" ]] && local site_nginxhelper="1" || local site_nginxhelper="0"
            [[ "$(wp --allow-root --path=/var/www/$site/htdocs plugin list | grep -i redis-cache | awk '{print $2}')" == "active" ]] && local site_redis="1" || local site_redis="0"
            # [[ "$(wp --allow-root plugin list | grep -i w3-total-cache | awk '{print $2}')" == "active" ]] && local site_w3tc="1" || local site_w3tc="0"
            # [[ "$(wp --allow-root plugin list | grep -i wp-super-cache | awk '{print $2}')" == "active" ]] && local site_wpsc="1" || local site_wpsc="0"
            # [[ "$(wp --allow-root plugin list | grep -i wp-rocket | awk '{print $2}')" == "active" ]] && local site_wprocket="1" || local site_wprocket="0"
        else
            local site_nginxhelper="0"
            local site_redis="0"
            # local site_w3tc="-"
            # local site_wpsc="-"
            # local site_wprocket="-"
        fi

        local site_sftp_user="$(cat /opt/sftp/users.conf | grep "^$site" | cut -d ':' -f1)"
        local site_sftp_pass="$(cat /opt/sftp/users.conf | grep "^$site" | cut -d ':' -f2)"
        
        # Get project_name from database
        local project_name=$(mysql wordops -u wordops -pwordops -sN -e "SELECT project_name FROM wordops_facts WHERE web_url='$site_name';")
        [[ -z "$project_name" ]] && project_name="-"

        json+="{\"web_url\": \"$site_name\", \"site_type\": \"$site_type\", \"php_version\": \"${php_version:-0}\", \"cf_proxy\": \"${site_cfproxy:-0}\", \"nginx_helper\": \"${site_nginxhelper:-0}\", \"wp_redis\": \"${site_redis:-0}\", \"sftp_user\": \"${site_sftp_user:--}\", \"sftp_pass\": \"${site_sftp_pass:--}\", \"project_name\": \"${project_name}\" },"
    done
    json=$(echo $json | sed 's/,$//')
    json+=']'

    echo $json
}

#~ list backups
list_backups() {
    list_mode=${list_mode:-raw}
    list_from=${list_from:-local}
    list_title=${list_title:-"[local] List of sites on local machine ($HOSTNAME)"}

    if [[ "$list_from" == "local" ]]; then
        inventory=($(wo site list | ansi2txt | sort))
    elif [[ "$list_from" == "remote" ]]; then
        inventory=($(mc ls $MINIO_PATH/$HOSTNAME/${site_name:+$site_name} | sort | awk '{print $NF}' | sed 's|/||g'))
    else
        echo -e "$color_red [ FAIL ] Invalid list_from value: $list_from, aborting..."
        return 1
    fi

    [[ "$list_mode" == "raw" ]] && {
        echo "${inventory[@]}" | sed 's/ /\n/g'
        return 0
    }

    OLDIFS=$IFS
    IFS=$'\n'

    title="# $list_title #"
    for z in $(seq 1 ${#title}); do printf "#"; done
    printf "\n$title\n"
    for z in $(seq 1 ${#title}); do printf "#"; done
    printf "\n"
    [[ "${#inventory[@]}" == "0" ]] && { [[ -z "${inventory[0]}" ]] && {
        inventory=("Error: Site not found in MinIO, aborting...")
        count="1"
        emptyset="1"
    }; }
    for z in $(seq 0 $((${#inventory[@]} - 1))); do
        printf "# %-$((${#title} - 4))s #\n" "${inventory[$z]}"
    done
    for z in $(seq 1 ${#title}); do printf "#"; done
    printf "\n"

    IFS=$OLDIFS

    [[ "$emptyset" == "1" ]] && return 1
}

report_status() {
    [[ "$CRON_MODE" != "1" ]] && return 0
    if [[ "$(cat /tmp/wordops-manager.log | sed '1d' | grep '\[ FAIL \]' | wc -l)" != "0" ]]; then
        local alarm_text='```\n'
        alarm_text+=$(cat /tmp/wordops-manager.log | grep -v '\[  OK  \]' | awk '{printf "%s\\n", $0}' | sed 's/"/\\"/g')
        alarm_text+='```'
        local payload='{'"\"text\""': '"\"$alarm_text\""'}'

        curl -X POST -H "Content-Type: application/json" -d "$payload" "$ALARM_WEBHOOK_URL" &>/dev/null
    fi
}

#~ save facts
save_fact() {
    local site_facts site_facts_count
    check_database
    if [[ "$1" == "all" ]]; then
        site_facts=$(get_facts)
    else
        site_facts=$(get_facts "$1")
    fi

    site_facts_count=$(echo "$site_facts" | jq '. | length')
    for ((i = 0; i < site_facts_count; i++)); do
        local web_url site_type php_version cf_proxy nginx_helper wp_redis sftp_user sftp_pass project_name
        web_url=$(echo "$site_facts" | jq -r ".[$i].web_url")
        site_type=$(echo "$site_facts" | jq -r ".[$i].site_type")
        php_version=$(echo "$site_facts" | jq -r ".[$i].php_version")
        cf_proxy=$(echo "$site_facts" | jq -r ".[$i].cf_proxy")
        nginx_helper=$(echo "$site_facts" | jq -r ".[$i].nginx_helper")
        wp_redis=$(echo "$site_facts" | jq -r ".[$i].wp_redis")
        sftp_user=$(echo "$site_facts" | jq -r ".[$i].sftp_user")
        sftp_pass=$(echo "$site_facts" | jq -r ".[$i].sftp_pass")
        current_project_name=$(echo "$site_facts" | jq -r ".[$i].project_name")

        if [[ "$CRON_MODE" != "1" ]]; then
            read -p "$(echo -e "$color_yellow [ ???? ] Do you want to update/add Project name for $web_url? Current project_name: $current_project_name (y/N): ")" question
            [[ "$question" == "y" ]] && read -p "$(echo -e "$color_yellow [ ???? ] Project name for $web_url: ")" project_name
            if [[ "$site_type" == "WordPress" ]]; then
                echo -e "$color_blue [ INFO ] WordPress site detected."
                read -p "$(echo -e "$color_yellow [ ???? ] Do you want to update WordPress admin URL, username and password for $web_url? (y/N): ")" question
                if [[ "$question" == "y" ]]; then
                    read -p "$(echo -e "$color_yellow [ ???? ] WordPress admin URL: ")" wp_admin_url
                    read -p "$(echo -e "$color_yellow [ ???? ] WordPress admin username: ")" wp_admin_user
                    read -p "$(echo -e "$color_yellow [ ???? ] WordPress admin password: ")" wp_admin_pass
                fi
            fi
        fi

        local fact_exists=$(mysql wordops -u wordops -pwordops -e "SELECT web_url FROM wordops_facts WHERE web_url='"$web_url"';")
        if [[ -z $fact_exists ]]; then
            if [[ "$site_type" == "Static" ]]; then
                php_version="-"
            elif [[ "$site_type" == "WordPress" ]]; then
                [[ -z "$wp_admin_url" ]] && { wp_admin_url="-"; }
                [[ -z "$wp_admin_user" ]] && { wp_admin_user="-"; }
                [[ -z "$wp_admin_pass" ]] && { wp_admin_pass="-"; }
            fi
            [[ -z "$project_name" ]] && { project_name="-"; }
            database_manager "insert" "\"$web_url\", \"$site_type\", \"$php_version\", \"$cf_proxy\", \"$nginx_helper\", \"$wp_redis\", \"$wp_admin_url\", \"$wp_admin_user\", \"$wp_admin_pass\", \"$sftp_user\", \"$sftp_pass\", \"$project_name\""
        else
            database_manager "update" "site_type" "\"$site_type\"" "\"$web_url\""
            [[ "$site_type" == "Static" ]] && { database_manager "update" "php_version" "\"-\"" "\"$web_url\""; } || { database_manager "update" "php_version" "\"$php_version\"" "\"$web_url\""; }
            database_manager "update" "cf_proxy" "\"$cf_proxy\"" "\"$web_url\""
            database_manager "update" "nginx_helper" "\"$nginx_helper\"" "\"$web_url\""
            database_manager "update" "wp_redis" "\"$wp_redis\"" "\"$web_url\""
            [[ -n "$project_name" ]] && database_manager "update" "project_name" "\"$project_name\"" "\"$web_url\""
            if [[ "$site_type" == "WordPress" ]]; then
                [[ ! -z "$wp_admin_url" ]] && { database_manager "update" "wp_admin_url" "\"$wp_admin_url\"" "\"$web_url\""; }
                [[ ! -z "$wp_admin_user" ]] && { database_manager "update" "wp_admin_username" "\"$wp_admin_user\"" "\"$web_url\""; }
                [[ ! -z "$wp_admin_pass" ]] && { database_manager "update" "wp_admin_password" "\"$wp_admin_pass\"" "\"$web_url\""; }
            else
                database_manager "update" "wp_admin_url" "\"-\"" "\"$web_url\""
                database_manager "update" "wp_admin_username" "\"-\"" "\"$web_url\""
                database_manager "update" "wp_admin_password" "\"-\"" "\"$web_url\""
            fi
            database_manager "update" "sftp_user" "\"$sftp_user\"" "\"$web_url\""
            database_manager "update" "sftp_pass" "\"$sftp_pass\"" "\"$web_url\""
        fi
    done
}

#~ restore backup
restore_backup() {
    local tmpdir=$(mktemp -d)
    echo -e "$color_blue [ INFO ] Restoring backup..."

    [[ "$@" =~ "tar.gz" ]] && { local backup_file="$@"; } || {
        download_backup
        local backup_file="$backup_file_name"
    }
    [[ ! -e $backup_file ]] && {
        echo -e "$color_red [ FAIL ] Backup file not found, aborting..."
        return 1
    }

    cp -r $backup_file $tmpdir/

    cd $tmpdir || {
        echo -e "$color_red [ FAIL ] Failed to change directory to $tmpdir, aborting..."
        return 1
    }
    tar -xzf $backup_file && { echo -e "$color_green [  OK  ] Backup file extracted successfully..."; } || {
        echo -e "$color_red [ FAIL ] Failed to extract backup file, aborting..."
        return 1
    }
    . */siteinfo.txt

    [[ -z "$wo_site_name" ]] && {
        echo -e "$color_red [ FAIL ] Invalid backup file, aborting..."
        return 1
    }

    echo -e "$color_yellow [ INFO ] Site name: $wo_site_name"
    echo -e "$color_yellow [ INFO ] Site type: $wo_site_type"
    echo -e "$color_yellow [ INFO ] Site root: $tmpdir/$wo_site_root"
    [[ ! -z "$wo_site_config" ]] && echo -e "$color_yellow [ INFO ] Site config: $tmpdir/$wo_site_config"
    [[ ! -z "$wo_site_db_file" ]] && echo -e "$color_yellow [ INFO ] Site database: $tmpdir/$wo_site_db_file"

    [[ -d "/var/www/$wo_site_name/backup" ]] && rm -rf "/var/www/$wo_site_name/backup"
    mkdir "/var/www/$wo_site_name/backup"

    if [[ "$wo_site_type" == "wp" ]]; then
        if [[ -e "/var/www/$wo_site_name/htdocs/wp-config.php" ]]; then
            local wp_config_file=("$wo_site_config" "/var/www/$wo_site_name/htdocs/wp-config.php")
        elif [[ -e "/var/www/$wo_site_name/wp-config.php" ]]; then
            local wp_config_file=("$wo_site_config" "/var/www/$wo_site_name/wp-config.php")
        fi

        local wp_content_dir=("$wo_site_root" "/var/www/$wo_site_name/htdocs/wp-content")

        echo -e "$color_blue [ INFO ] Taking backup of existing site..."
        pushd /var/www/$wo_site_name/htdocs &>/dev/null
        wp --allow-root db export /var/www/$wo_site_name/backup/$wo_site_name.sql &>/dev/null && echo -e "$color_green [  OK  ] Database backup exported successfully in /var/www/$wo_site_name/backup/$wo_site_name.sql..." || {
            echo -e "$color_red [ FAIL ] Failed to export database backup..."
            return 1
        }
        popd &>/dev/null
        mv "${wp_config_file[1]}" "/var/www/$wo_site_name/backup/" || {
            echo -e "$color_red [ FAIL ] Failed to move wp-config.php to /var/www/$wo_site_name/backup/"
            return 1
        }
        mv "${wp_content_dir[1]}" "/var/www/$wo_site_name/backup/" || {
            echo -e "$color_red [ FAIL ] Failed to move wp-content to /var/www/$wo_site_name/backup/"
            return 1
        }
        echo -e "$color_green [  OK  ] Backup of existing site taken successfully in /var/www/$wo_site_name/backup/"

        echo -e "$color_blue [ INFO ] Restoring backup files from $tmpdir/$wo_site_name to /var/www/$wo_site_name/"
        mv "${wp_config_file[0]}" "${wp_config_file[1]}" || {
            echo -e "$color_red [ FAIL ] Failed to move wp-config.php to /var/www/$wo_site_name/htdocs/"
            return 1
        }
        mv "${wp_content_dir[0]}" "${wp_content_dir[1]}" || {
            echo -e "$color_red [ FAIL ] Failed to restore wp-content to /var/www/$wo_site_name/htdocs/"
            return 1
        }
        mv "$wo_site_db_file" "/var/www/$wo_site_name/htdocs/" || {
            echo -e "$color_red [ FAIL ] Failed to move sql database to /var/www/$wo_site_name/htdocs/"
            return 1
        }
        echo -e "$color_green [  OK  ] Backup files restored from $tmpdir/$wo_site_name to /var/www/$wo_site_name/"

        chown -R www-data: /var/www/$wo_site_name/htdocs

        pushd /var/www/$wo_site_name/htdocs &>/dev/null
        wp --allow-root db import $wo_site_name.sql &>/dev/null && echo -e "$color_green [  OK  ] Database imported successfully from /var/www/$wo_site_name/htdocs/$wo_site_name.sql" || {
            echo -e "$color_red [ FAIL ] Failed to import database..."
            return 1
        }
        rm -f $wo_site_name.sql
        popd &>/dev/null
    elif [[ "$wo_site_type" == "mysql" ]]; then
        local db_name=$(wo site info $wo_site_name | grep 'DB_NAME' | awk '{print $2}')
        local db_user=$(wo site info $wo_site_name | grep 'DB_USER' | awk '{print $2}')
        local db_pass=$(wo site info $wo_site_name | grep 'DB_PASS' | awk '{print $2}')

        echo -e "$color_blue [ INFO ] Taking backup of existing site..."
        mv /var/www/$wo_site_name/htdocs /var/www/$wo_site_name/backup/ || {
            echo -e "$color_red [ FAIL ] Failed to move existing site files to /var/www/$wo_site_name/backup/"
            return 1
        }
        mysqldump -h localhost -u $db_user -p$db_pass $db_name >/var/www/$wo_site_name/backup/$wo_site_name.sql || {
            echo -e "$color_red [ FAIL ] Failed to take backup of existing database..."
            return 1
        }
        echo -e "$color_green [  OK  ] Backup of existing site taken successfully..."

        echo -e "$color_blue [ INFO ] Restoring files from $tmpdir/$wo_site_name to /var/www/$wo_site_name/"
        mv ${wo_site_root} /var/www/$wo_site_name/ || {
            echo -e "$color_red [ FAIL ] Failed to move site files to /var/www/$wo_site_name/"
            return 1
        }
        mysql -h localhost -u $db_user -p$db_pass $db_name <${wo_site_db_file} || {
            echo -e "$color_red [ FAIL ] Failed to restore database..."
            return 1
        }
        echo -e "$color_green [  OK  ] Site files restored..."

        chown -R www-data: /var/www/$wo_site_name/htdocs
    elif [[ "$wo_site_type" =~ "php" || "$wo_site_type" == "html" ]]; then
        echo -e "$color_blue [ INFO ] Taking backup of existing site..."
        mv /var/www/$wo_site_name/htdocs /var/www/$wo_site_name/backup/ && echo -e "$color_green [  OK  ] Backup of existing site taken successfully in /var/www/$wo_site_name/backup/" || {
            echo -e "$color_red [ FAIL ] Failed to move existing site files to /var/www/$wo_site_name/backup/"
            return 1
        }
        mv ${wo_site_root} /var/www/$wo_site_name/ || {
            echo -e "$color_red [ FAIL ] Failed to move site files to /var/www/$wo_site_name/"
            return 1
        }
        echo -e "$color_green [  OK  ] Site files restored..."

        chown -R www-data: /var/www/$wo_site_name/htdocs
    fi

    echo -e "$color_blue [ INFO ] Restarting WordOps backend..."
    wo stack restart &>/dev/null && echo -e "$color_green [  OK  ] WordOps backend restarted successfully..." || {
        echo -e "$color_red [ FAIL ] Failed to restart WordOps backend..."
        return 1
    }
    wo clean --all &>/dev/null && echo -e "$color_green [  OK  ] WordOps cache cleaned successfully..." || {
        echo -e "$color_red [ FAIL ] Failed to clean WordOps cache..."
        return 1
    }
    echo -e "$color_green [  OK  ] Restarted WordOps successfully...\n$color_reset"

    cd /tmp
    rm -rf $tmpdir
}

function check_deleted() {
    local wo_list facts_list
    mapfile -t facts_list < <(mysql wordops -u wordops -pwordops -sN -e "SELECT web_url FROM wordops_facts;")
    mapfile -t wo_list < <(wo site list | sed -r "s/[[:cntrl:]]\[[0-9]{1,3}m//g")
    for fact_site in "${facts_list[@]}"; do
        if ! containsElement "$fact_site" "${wo_list[@]}"; then
            echo -e "$color_yellow [ ???? ]$color_reset $fact_site seems to be deleted. Removing it from facts."
            database_manager "delete" "\"$fact_site\""
        fi
    done
}

#~ usage
usage() {
    echo "Usage: $(basename $0) [OPTION]..."
    echo "  -b, --backup <site>          Backup site"
    echo "  -c, --config <file>          Use given config file"
    echo "  -C, --check-crontab          Check crontab"
    echo "  -d, --download               Download backup"
    echo "  -l, --list <local|remote>    List backups"
    echo "  -r, --restore <file>         Restore backup"
    echo "  -S, --save <site>            Save site facts"
    echo "  -s, --status                 Check backup status"
    echo "  -V, --validate               Validate script and exit"
    echo "  -v, --version                Display version information and exit"
    echo "  -h, --help                   Display this help and exit"
}

#~ main
main() {
    opt=($(getopt -l "backup:,config:,check-crontab,download,list:,restore:,save:,status,validate,version,help" -o "b:,c:,C,d,l:,r:,S:,s,V,v,h" -n "$0" -- "$@"))
    [[ "${#opt[@]}" == "1" ]] && {
        usage
        exit 1
    }
    eval set -- "${opt[@]}"

    CONFIG_PATH="/etc/wordops-manager.conf"
    [[ "$1" == '-c' ]] || [[ "$1" == '--config' ]] && { [[ -n $2 ]] && CONFIG_PATH=$2; }
    check_config "$CONFIG_PATH" && . "$CONFIG_PATH"

    while true; do
        case $1 in
        -b | --backup)
            backup_site "$2"
            report_status
            break
            ;;
        -C | --check-crontab)
            check_crontab
            ;;
        -c | --config)
            shift
            ;;
        -d | --download)
            download_backup
            ;;
        -l | --list)
            list_mode=nonraw list_from=$2 list_title="[$2] List of backups from $2 ($HOSTNAME)" list_backups
            ;;
        -r | --restore)
            restore_backup "$2"
            report_status
            break
            ;;
        -S | --save)
            save_fact "$2"
            ;;
        -s | --status)
            backup_status
            ;;
        -V | --validate)
            echo -e "$color_green [  OK  ] Script validated successfully..."
            ;;
        -v | --version)
            echo "WordOps Manager: $script_version"
            ;;
        --)
            shift
            return 0
            ;;
        -h | --help)
            usage
            break
            ;;
        esac
        _status="$?"
        [[ "${_status}" != "0" ]] && { exit ${_status}; }
        shift
    done
}

check_deleted
main "$@"
