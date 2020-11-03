#!/bin/bash
set -ue
#set -x

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of this
# software and associated documentation files (the "Software"), to deal in the Software
# without restriction, including without limitation the rights to use, copy, modify,
# merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
# INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
# PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
# HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
# SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#
#====================================================================================
#* SET variables*
#SID of ASE Instance
ASE_SERVER=S01
# SAP ASE SA user: sapsa
SA_USER=sapsa
# User: syb<sid>
SYBADM=sybs01
# aseuserstore key name for SSO
SYBKEYNAME=SYBS01
# To be adjusted by the customer - requirements in which zone(s) they want to have the fast snapshot restore available for instance failover separated by spaces not comma! Leve empty if no fast snapshot should be disabled.
azs=""
#azs="eu-west-1a"

######################################################################################################
########################                                                      ########################
##################                   no changes below this line!                    ##################
##                                                                                                  ##
##                                     Create EBS Snapshots                                         ##
##                                         for SAP ASE                                              ##
##################                                                                  ##################
########################                                                      ########################
######################################################################################################
#* SET more variables automatically - do not change anything!
# ASE variables
SYBASE=$(su $SYBADM -c 'echo $SYBASE')
SYBASE_ASE=$(su $SYBADM -c 'echo $SYBASE_ASE')

# Instance details:
az=`curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone`
region="`echo \"$az\" | sed 's/[a-z]$//'`"
instance_id=`curl -s http://169.254.169.254/latest/meta-data/instance-id`
CFGFIL=$SYBASE/$SYBASE_ASE/$ASE_SERVER.cfg

#Log output to AWS console log
logfile="/var/log/user-data.log"


# Exit if a pipeline results in an error.
set -ue
set -o pipefail

#********************** Function Declarations ************************************************************************

# Function: Log an event.
log() {
    echo "[$(date +"%Y-%m-%d"+"%T")]: $*"
}


# Function: Prerequisite Check - ASE environment.
prerequisite_check() {
   if [ -z "$SYBASE" ] || [ -z "$SYBASE/$SYBASE_ASE" ]
   then
      log "ERROR: SYBASE environment not correctly set."
      return 1
   fi
   if [ ! -d "$SYBASE" ] || [ ! -d "$SYBASE/$SYBASE_ASE" ]
   then
      log "ERROR: Directory $SYBASE or $SYBASE/$SYBASE_ASE not found. Check the environment."
      return 1
   fi

  sudo -u ${SYBADM} -i isql -k${SYBKEYNAME} -X -e -b --retserverror -o unquiesce << EOSQL
  select @@sqlstatus
  go
EOSQL
   if [ $? -ne 0 ]
		then
		log "ERROR: Database not online or connection not possible!"
   fi
return 0
}


# Function: Quiesce all non temporary databases.
quiesce_all() {
  log "INFO: Quiescing databases"
  sudo -u ${SYBADM} -i isql -k${SYBKEYNAME} -w 1024 -X -e -b --retserverror -o do_quiesce << EOSQL
set nocount on
go
prepare database all_tag hold master, model, $ASE_SERVER, saptools, sybsystemdb, sybsystemprocs, sybmgmtdb for external dump with quiesce
go
EOSQL
  if [ $? -ne 0 ]
    then
      log "ERROR: Quiescing command faild!"
      cat ${SYBASE}/do_quiesce >>${logfile}
  fi
}


# Function: Unquiesce all.
unquiesce_all()
{
log "INFO: Unquiescing databases"
sudo -u ${SYBADM} -i isql -k${SYBKEYNAME} -X -e -b --retserverror -o unquiesce << EOSQL
prepare database all_tag release
go
EOSQL
if [ $? -ne 0 ]
then
  log "Unquiesce command failed!"
  cat ${SYBASE}/unquiesce >>${logfile}
fi
return 0
}


# Function: Create snapshot.
snapshot_instance() {
    snapshot_description="$(hostname)-$instance_id-ASE-Snapshot-$(date +%Y-%m-%d-%H:%M:%S)"

    recent_snapshot_list_new=($(aws ec2 create-snapshots --region ${region} --instance-specification InstanceId=${instance_id},ExcludeBootVolume=true --description ${snapshot_description} --tag-specifications "ResourceType=snapshot,Tags=[{Key=Createdby,Value=AWS-ASE-Snapshot_of_${HOSTNAME}}]" | jq -r ".Snapshots[] | .SnapshotId"))
    for ((i=0; i<${#recent_snapshot_list_new[@]}; ++i)); do     log "INFO: EBS Snapshot ID-$i: ${recent_snapshot_list_new[$i]}"; done
}


# Function: Add device name to snapshot tags.
tag_mountinfo() {
    OIFS=$IFS;
    IFS=",";
    declare -a volume_id_sorted
    declare -a device_name_sorted
    for ((i=0; i<${#recent_snapshot_list_new[@]}; ++i));
    do
        #get device name of volume
        volume_id_sorted+=($(aws ec2 describe-snapshots --region ${region} --snapshot-ids ${recent_snapshot_list_new[$i]} | jq -r ".Snapshots[] | .VolumeId"))
        device_name_sorted+=($(aws ec2 describe-volumes --region ${region} --output=text --volume-ids ${volume_id_sorted[$i]} --query 'Volumes[0].{Devices:Attachments[0].Device}'))

        #add tag to snapshot
        aws ec2 create-tags --region ${region} --resource ${recent_snapshot_list_new[$i]} --tags Key=device_name,Value=${device_name_sorted[$i]}
    done

    IFS=$OIFS;
}

# Function: Enable fast snapshot restore
fast_snap()
{
    if [ -z "$azs" ]
    then
      log "INFO: Fast snapshot restore option is disabled"
    else
      for ((i=0; i<${#recent_snapshot_list_new[@]}; ++i));
      do
          aws ec2 enable-fast-snapshot-restores --region ${region} --availability-zones ${azs} --source-snapshot-ids ${recent_snapshot_list_new[$i]} --output table
          log "INFO: Fast snapshot restore enabled for snapshot ${recent_snapshot_list_new[$i]} in availability zone ${azs}"
      done
    fi

}


# Function: Enter dummy entry into dumphist file - Optional step, because dump history feature cannot be used with external backups. See SAP Note 1887068
#upd_dumphist()
##{
#log "INFO: Updating dump history file"
#sudo -u ${SYBADM} -i isql -k${SYBKEYNAME} -b -w 1024 -X --retserverror << EOSQL >>${DUMPHISTFILE}
#set nocount on
#go
#declare dbn_curs cursor for SELECT dbid, name from master..sysdatabases
#where durability != 6 --exclude temporary databases
#go
#declare @curseq varchar(109)
#declare @dumphist_str varchar(1024)
#declare @dbn varchar(256)
#declare @db_id integer
#open dbn_curs
#fetch dbn_curs into @db_id , @dbn
#while @@sqlstatus = 0
#begin
#  select @curseq = convert(varchar(26),convert(datetime,dbinfo_get(@dbn,'curseqnum')),109)
#  select @dumphist_str = "2|" || CONVERT(VARCHAR(7),@db_id) || "|" || @dbn || "|1|Jan  1 1900 12:00:00:000AM|" || @curseq || "|" || @curseq || "|EXTERNAL_DUMP|0|*|0|0|1"
#  print "%1!", @dumphist_str
#  fetch dbn_curs into @db_id , @dbn
#end
#go
#EOSQL
#if [ $? -ne 0 ]
#then
#  log "WARNING: Update of dump history file ${DUMPHISTFILE} failed!"
#  return 1
#fi
#return 0
#}


#**********************************************************************************************************************************
### Call functions in required order
log "INFO: Start AWS snapshot backup"

#log_setup
log "INFO: Check log file $logfile for more information"

# 1) Check prerequisites
if prerequisite_check; then :
else log "ERROR: Environment not set correctly or database not online no connection possible"
   exit 1
fi


# 2) Backup Dumhistory
DUMPHIST_ENABLED=`grep 'enable dump history' ${CFGFIL}  | awk '{print $5}'`
if [ ${DUMPHIST_ENABLED} -eq 1 ]
then
  DUMPHISTFILE=`grep  'dump history filename' ${CFGFIL} | awk '{print $5}'`
  if [ "${DUMPHISTFILE}" == "DEFAULT" ]
  then
    DUMPHISTFILE=${SYBASE}/${SYBASE_ASE}/dumphist
  fi
  log "INFO: Dump history file : ${DUMPHISTFILE}"
  else
  log "INFO: Dump history file : ${DUMPHISTFILE}"
fi

# 3) Quiesce DB
if quiesce_all; then :
else log "ERROR: Quiescing of databases failed!"
   exit 1
fi

# 4) Execute EBS Snapshot
if snapshot_instance; then :
else log "ERROR: EBS Snapshot was not successful"
   exit 1
fi

# Optional Update dump history
#upd_dumphist


# 5) Unquiesce DB
if unquiesce_all; then :
else log "ERROR: Databases not released for write access !"
   exit 1
fi

# 6) Tag snapshot with device name
if tag_mountinfo; then :
else log "ERROR: Could not create tags for EBS snapshots"
   exit 1
fi

# 7) Enable fast snapshot restore
if fast_snap; then :
else log "ERROR: Could not enable fast snapshot restore"
    exit 1
fi

log "INFO: End of AWS snapshot backup"

exit 0
#################################################################End of script ########################################