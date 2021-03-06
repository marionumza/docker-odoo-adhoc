#!/bin/bash
# from odoo entrypoint
set -e

# set odoo database host, port, user and password
: ${PGHOST:=$DB_PORT_5432_TCP_ADDR}
: ${PGPORT:=$DB_PORT_5432_TCP_PORT}
: ${PGUSER:=${DB_ENV_POSTGRES_USER:='postgres'}}
: ${PGPASSWORD:=$DB_ENV_POSTGRES_PASSWORD}
export PGHOST PGPORT PGUSER PGPASSWORD

# copy_sources
function copy_sources {
    echo "Making a copy of Extra Addons to Custom addons"
    cp -R $EXTRA_ADDONS/* $CUSTOM_ADDONS
}

if [ "$*" == "copy_sources" ]; then
    copy_sources
    exit 1
fi

# copy_nginx_conf
# function copy_nginx_conf {
#     echo "Making a copy of nginx data to odoo data folder"
#     cp -R $RESOURCES/nginx $DATA_DIR/
# }

# TODO chequear si existe y no sobre escribir?
# copy_nginx_conf

# Ensure proper content for $UNACCENT
if [ "$UNACCENT" != "True" ]; then
    UNACCENT=False
fi

# get DB max connections, if you set workers, each worker can have db_maxconn, and total connectios need to be less than PG_MAX_CONNECTIONS
# by default postgres allow 100
#PG_MAX_CONNECTIONS=100
if (($WORKERS > 0)); then
    DB_MAXCONN=`expr $PG_MAX_CONNECTIONS / $WORKERS`
fi
if (($WORKERS <= 0)); then
    DB_MAXCONN=32
fi

# empezó a darnos error si no pasamos esto, algo con el view.rng, sin , al final para que no cargue / como path
ODOO_ADDONS="/usr/lib/python2.7/dist-packages/openerp/addons"
# por error con upgrades que dice que esta mal este dir, probamos sacarlo "/opt/odoo/data/addons/9.0"
# ODOO_ADDONS="/opt/odoo/data/addons/9.0,/usr/lib/python2.7/dist-packages/openerp/addons"

# we add sort to find so ingadhoc paths are located before the others and prefered by odoo
echo Patching configuration > /dev/stderr
addons=$(find $CUSTOM_ADDONS $EXTRA_ADDONS -mindepth 1 -maxdepth 1 -type d | sort | tr '\n' ',')$ODOO_ADDONS
echo "
[options]
; Configuration file generated by $(readlink --canonicalize $0)
addons_path = " $addons "
unaccent = $UNACCENT
workers = $WORKERS
max_cron_threads = $MAX_CRON_THREADS
db_user = $PGUSER
db_password = $PGPASSWORD
db_host = $PGHOST
db_template = $DB_TEMPLATE
admin_passwd = $ADMIN_PASSWORD
data_dir = $DATA_DIR
proxy_mode = $PROXY_MODE
without_demo = $WITHOUT_DEMO
server_wide_modules = $SERVER_WIDE_MODULES
dbfilter = $DBFILTER
# auto_reload = True

# odoo saas parameters
server_mode = $SERVER_MODE
disable_session_gc = $DISABLE_SESSION_GC
filestore_operations_threads = $FILESTORE_OPERATIONS_THREADS

# smtp server configuration
smtp_server = $SMTP_SERVER
smtp_port = $SMTP_PORT
smtp_ssl = $SMTP_SSL
smtp_user = $SMTP_USER
smtp_password = $SMTP_PASSWORD

# other performance parameters
db_maxconn = $DB_MAXCONN
limit_memory_hard = $LIMIT_MEMORY_HARD
limit_memory_soft = $LIMIT_MEMORY_SOFT
# limit_request = 8192
limit_time_cpu = $LIMIT_TIME_CPU
limit_time_real = $LIMIT_TIME_REAL

# aeroo config
aeroo.docs_enabled = True
aeroo.docs_host = $AEROO_DOCS_HOST

# afip certificates
afip_homo_pkey_file = $AFIP_HOMO_PKEY_FILE
afip_homo_cert_file = $AFIP_HOMO_CERT_FILE
afip_prod_pkey_file = $AFIP_PROD_PKEY_FILE
afip_prod_cert_file = $AFIP_PROD_CERT_FILE

" > $ODOO_CONF

# default mail catchall domain, lo usamos para que se establezca por defecto en los containers y que luego el usuario si quiere lo pueda sobreescribir con el parametro
if [ "$MAIL_CATCHALL_DOMAIN" != "" ]; then
    echo "mail.catchall.domain = $MAIL_CATCHALL_DOMAIN" >> $ODOO_CONF
fi

# If database is available, use it
if [ "$DATABASE" != "" ]; then
    echo "db_name = $DATABASE" >> $ODOO_CONF
fi

# Know if Postgres is listening
function db_is_listening() {
    psql --list > /dev/null 2>&1 || (sleep 1 && db_is_listening)
}

echo Waiting until the database server is listening... > /dev/stderr
db_is_listening

# Check pg user exist
function pg_user_exist() {
    psql postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='$PGUSER'" > /dev/null 2>&1 || (sleep 1 && pg_user_exist)
}

echo Waiting until the pg user $PGUSER is created... > /dev/stderr
pg_user_exist

# Add the unaccent module for the database if needed
if [ "${UNACCENT,,}" == "true" ]; then
    echo Trying to install unaccent extension > /dev/stderr
    psql -d $DB_TEMPLATE -c 'CREATE EXTENSION IF NOT EXISTS unaccent;'
fi

# por compatibilidad para atras, si mandamos true, entonces manda fix sin pasar
# bds, si mandamos otra cosa, entonces pasamos eso como bds, esto es necesario sobre todo porque
# ahora no compartimos posgres y las bds son visibles, luego lo podremos mejorar con usuarios pero igual
# puede ser un problema porque se compartiría dentro de mismo usuario
if [ "${FIXDBS,,}" == "true" ]; then
    echo Trying to fix databases > /dev/stderr
    $ODOO_SERVER fixdb --workers=0 --no-xmlrpc
elif [ "$FIXDBS" != "" ] && [ "${FIXDBS,,}" != "false" ]; then
    echo Trying to fix databases > /dev/stderr
    $ODOO_SERVER fixdb --workers=0 --no-xmlrpc -d $FIXDBS
fi

# Run server
echo "Running command..."
case "$1" in
    --)
        shift
        exec $ODOO_SERVER "$@"
        ;;
    -*)
        exec $ODOO_SERVER "$@"
        ;;
    *)
        exec "$@"
esac

exit 1
