#!/usr/bin/env bash
#
# rmapplied-chan
# version 1.0
#
# / what's the rush? /
#

# usage
USAGE="\n\trmapplied - maintain removal of applied archivelogs for a standby database.\n\n \
\trmapplied.sh [-h] -s <ORACLE_SID>\n\n \
\t-h - print this message\n \
\t-s - database name\n\n \
\tNotes:\n\n \
\t- script logs can be found in '/u01/log/oracle' directory upon completion.\n\n \
\tExample:\n\n \
\t- remove archivelogs for database orcl:\n\n \
\t  rmapplied.sh -s orcl\n"

# options
while getopts 'hs:' opt
do
  case $opt in
  h) echo -e "${USAGE}"
     exit 0
     ;;
  s) SID=${OPTARG}
     ;;
  :) echo "option -$opt requires an argument"
     ;;
  *) echo -e "${USAGE}"
     exit 1
     ;;
  esac
done
shift $(($OPTIND - 1))

# error handling
function errck () {
  printf "\n\n*** $(date +%Y.%m.%d\ %H:%M:%S)\n${ERRMSG} Stop.\n" >> ${LOG} 2>&1
  exit 1
}

# check if zero
function check () {
  if [[ $? != 0 ]]; then
    printf "\n\n*** $(date +%Y.%m.%d\ %H:%M:%S)\n${ERRMSG} Stop.\n" >> ${LOG} 2>&1
    exit 1
  fi
}

function times () {
  printf "*** $(date +%Y.%m.%d\ %H:%M:%S)\n"
}

# set oracle environment
function setora () {
  ERRMSG="SID ${1} not found in ${ORATAB}."
  if [[ $(cat ${ORATAB} | grep "^$1:") ]]; then
    unset ORACLE_SID ORACLE_HOME ORACLE_BASE
    export ORACLE_BASE=/u01/app/oracle
    export ORACLE_SID=${1}
    export ORACLE_HOME=$(cat ${ORATAB} | grep "^${ORACLE_SID}:" | cut -d: -f2)
    export PATH=${ORACLE_HOME}/bin:${PATH}
  else
    errck
  fi
}

# os dependent
case $(uname) in
  "SunOS") ORATAB=/var/opt/oracle/oratab
           ;;
  "Linux") ORATAB=/etc/oratab
           ;;
  "AIX")   ORATAB=/etc/oratab
           ;;
  "HP-UX") ORATAB=/etc/oratab
           ;;
  *)       printf "Unknown OS.\n" && exit 13
           ;;
esac

# env initial
LOGDIR="/u01/log/oracle"
if [[ ! -d ${LOGDIR} ]]; then
  printf "Standard log directory is not available, attempting to create.\n"
  mkdir -p ${LOGDIR}
  if [[ $? != 0 ]]; then
    printf "Operation failed.\n"
    exit 1
  fi
fi
LOG=/u01/log/oracle/rmapplied_$(date +%Y.%m.%d.%H.%M).log

# var check
if [[ -z ${SID} ]]; then
  printf "<ORACLE_SID> is mandatory. Use -h.\n"
  exit 1
fi

# start
setora ${SID}
ERRMSG="Cannot get database status."
STATUS=$(printf "
  set head off verify off trimspool on feed off line 2000 pagesize 100 newpage none
  set numformat 9999999999999999999
  set pages 0
  select status from v\$instance;
  exit
  " | sqlplus -s / as sysdba | grep .)
check
if [[ ${STATUS} != "MOUNTED" ]]; then
  ERRMSG="Database ${SID} should be in MOUNTED state. Current status: ${STATUS}."
  errck
else
  ERRMSG="Cannot check database role."
  ROLE=$(printf "
    set head off verify off trimspool on feed off line 2000 pagesize 100 newpage none
    set numformat 9999999999999999999
    set pages 0
    select database_role from v\$database;
    exit
    " | sqlplus -s / as sysdba | grep .)
  check
  if [[ ${ROLE} != "PHYSICAL STANDBY" ]]; then
    ERRMSG="Database ${SID} is not a standby database. Current role: ${ROLE}."
    errck
  else
    ERRMSG="Cannot fetch sequence number."
    SEQ=$(printf "
      set head off verify off trimspool on feed off line 2000
      set numformat 9999999999999999999
      select max(a.sequence#)
      from v\$archived_log a where a.applied='YES';
      exit
      " | sqlplus -s "/ as sysdba" | grep . | awk '{print $1}')
    check
    ERRMSG="Cannot remove archivelogs."
    printf "$(times) Deleting archivelogs until sequence ${SEQ}.\n" >> ${LOG}
rman target / >> ${LOG} 2>&1 << EOF
crosscheck archivelog all;
delete noprompt archivelog until sequence ${SEQ};
EOF
    check
  fi
fi

# remove old logfiles
ERRMSG="Cannot remove old logfiles."
find ${LOG%/*} -name "rmapplied*" -mtime +3 -exec rm -f {} \; >> ${LOG} 2>&1
check

# exit
exit 0
