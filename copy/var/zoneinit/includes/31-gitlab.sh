
log "getting mysql_pw"

MYSQL_PW=${MYSQL_PW:-$(mdata-get mysql_pw 2>/dev/null)} || \
MYSQL_PW=$(od -An -N8 -x /dev/random | head -1 | tr -d ' ');

MYSQL_INIT="DELETE from mysql.user;
GRANT ALL on *.* to 'root'@'localhost' identified by '${MYSQL_PW}' with grant option;
GRANT ALL on *.* to 'root'@'${PRIVATE_IP:-${PUBLIC_IP}}' identified by '${MYSQL_PW}' with grant option;
CREATE DATABASE IF NOT EXISTS gitlabhq_production DEFAULT CHARACTER SET utf8 COLLATE utf8_unicode_ci;
CREATE USER 'gitlab'@'localhost' IDENTIFIED BY '${MYSQL_PW}';
GRANT SELECT, LOCK TABLES, INSERT, UPDATE, DELETE, CREATE, DROP, INDEX, ALTER ON gitlabhq_production.* TO 'gitlab'@'localhost';
DROP DATABASE test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;"

log "starting the MySQL instance"
svcadm enable percona

log "waiting for the socket to show up"
COUNT="0";
while [[ ! -e /tmp/mysql.sock ]]; do
        sleep 1
        ((COUNT=COUNT+1))
        if [[ $COUNT -eq 60 ]]; then
          log "ERROR Could not talk to MySQL after 60 seconds"
    ERROR=yes
    break 1
  fi
done
[[ -n "${ERROR}" ]] && exit 31
log "(it took ${COUNT} seconds to start properly)"

sleep 1

[[ "$(svcs -Ho state percona)" == "online" ]] || \
  ( log "ERROR MySQL SMF not reporting as 'online'" && exit 31 )

log "running the access lockdown SQL query"
mysql -u root -e "${MYSQL_INIT}" >/dev/null || \
  ( log "ERROR MySQL query failed to execute." && exit 31 )

log "configuring redis to bind to localhost only"
gsed -i \
        -e "s/# bind 127.0.0.1/bind 127.0.0.1/" \
        -e "s/# unixsocket \/tmp\/redis.sock/unixsocket \/tmp\/redis.sock/" \
        /opt/local/etc/redis.conf

log "starting the redis instance"
svcadm enable redis

log "waiting for the socket to show up"
COUNT="0";
while [[ ! -e /tmp/redis.sock ]]; do
        sleep 1
        ((COUNT=COUNT+1))
        if [[ $COUNT -eq 60 ]]; then
          log "ERROR Could not talk to redis after 60 seconds"
    ERROR=yes
    break 1
  fi
done
[[ -n "${ERROR}" ]] && exit 31
log "(it took ${COUNT} seconds to start properly)"

sleep 1

[[ "$(svcs -Ho state redis)" == "online" ]] || \
  ( log "ERROR redis SMF not reporting as 'online'" && exit 31 )

log "configuring git"
sudo -u git -H git config --global user.name "GitLab"
sudo -u git -H git config --global user.email "gitlab@localhost"
sudo -u git -H git config --global core.autocrlf input

log "configuring gitlab-shell"
cd /home/git/gitlab-shell

log "getting gitlab_root_pw"

GITLAB_ROOT_PW=${GITLAB_ROOT_PW:-$(mdata-get gitlab_root_pw 2>/dev/null)} || \
GITLAB_ROOT_PW="5iveL!fe";

log "configuring gitlab"
cd /home/git/gitlab
gsed -i \
        -e "s/%MYSQL_PW%/${MYSQL_PW}/" \
        /home/git/gitlab/config/database.yml
gsed -i \
        -e "s/%HOSTNAME%/${HOSTNAME}/" \
        /home/git/gitlab/config/gitlab.yml
sudo -u git -H bundle exec rake gitlab:setup RAILS_ENV=production GITLAB_ROOT_PASSWORD="${GITLAB_ROOT_PW}" force=yes

log "starting the postfix instance"
svcadm enable postfix

log "starting the gitlab-sidekiq instance"
svcadm enable gitlab-sidekiq

log "starting the gitlab instance"
svcadm enable gitlab

log "starting the nginx instance"
svcadm enable nginx
