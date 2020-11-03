#!/bin/bash
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
# Set Logging Options
logfile="/var/log/user-data.log"

#* SET variables*
#Parameter name for SSM of data and log volumes
SSMPARAMDATAVOL=sybase-datavol
SSMPARAMLOGVOL=sybase-logvol
# Server hostname
SERVER_NAME=sybdb01
#Server  fqdn
SERVER_FQDN=sybdb01.test-example.com
#Server virtual fqdn
SERVER_VIRT_FQDN=dbS01.test-example.com
#SID of ASE Instance
ASE_SERVER=S01
# SAP ASE SA user: sapsa
SA_USER=sapsa
# User: syb<sid>
SYBADM=sybs01
# aseuserstore key name for SSO
SYBKEYNAME=SYBS01
# Name of modified ASE config file
ASE_CFG=RUN_S01
# DNS zone and reverse IDs to manipulate Route 53
DNS_ZONE_ID=<zone-id>
DNS_ZONE_REV_ID=<rev-zone-id>
# Log transaction directory
TRANS_LOG_DIR="/sybase_backup/S01_logs"
# DNS JSON files directory
SCRIPTS_DIR="/sybase/${ASE_SERVER}"

######################################################################################################
########################                                                      ########################
##################                                                                  ##################
##                                                                                                  ##
##                         Restore Amazon Elastic Block Store (EBS) Snapshots                       ##
##                                                                                                  ##
##################                                                                  ##################
########################                                                      ########################
######################################################################################################
#* SET more variables automatically - do not change anything!
# Instance details:
INSTANCEID=`curl -s http://169.254.169.254/latest/meta-data/instance-id`
AZ=`curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone`
REGION="`echo \"$AZ\" | sed 's/[a-z]$//'`"
MAC=`curl -s http://169.254.169.254/latest/meta-data/mac`
ENI_ID=`curl -s http://169.254.169.254/latest/meta-data/network/interfaces/macs/${MAC}/interface-id`
# Point in time recovery date which is automatically set to current date


# Function: Log an event.
log() {
    echo "[$(date +"%Y-%m-%d"+"%T")]: $*"
}

#update IP in /etc/hosts
update_etc_hosts() {
    log "INFO : Updating hosts file"
    sed -i "/${SERVER_NAME}/d" /etc/hosts
    curl -s http://169.254.169.254/latest/meta-data/local-ipv4 >> /etc/hosts
    echo -n ' ' >> /etc/hosts
    echo -n ${SERVER_NAME} >> /etc/hosts
    echo -n ' ' >> /etc/hosts
    echo -n ${SERVER_FQDN} >> /etc/hosts
    echo -e "\n" >> /etc/hosts
}

# restart AWS SSM agent
restart_ssm() {
    log "INFO : Restarting SSM agent"
    sudo systemctl stop amazon-ssm-agent
    sudo systemctl start amazon-ssm-agent
}

attach_secondary_ip() {
    log "INFO : Attaching secondary IP"
    aws ec2 assign-private-ip-addresses --network-interface-id ${ENI_ID} --secondary-private-ip-address-count 1 --region ${REGION}
    sleep 20
    SEC_IP=`curl -s http://169.254.169.254/latest/meta-data/network/interfaces/macs/${MAC}/local-ipv4s|awk 'FNR == 2 {print}'`
    log "INFO : Secondary IP is ${SEC_IP}"

}

# update route 53 and hosts for VIP
update_route53() {
    log "INFO : Update Route 53 domain name"
    #SEC_IP=`curl -s http://169.254.169.254/latest/meta-data/network/interfaces/macs/${MAC}/local-ipv4s|awk 'FNR == 2 {print}'`
    log "INFO : Secondary IP is ${SEC_IP}"
    INPUT_JSON_A=$( cat ${SCRIPTS_DIR}/a-record-route53.json | sed "s/IP_CHANGE/$SEC_IP/" )
    aws route53 change-resource-record-sets --hosted-zone-id $DNS_ZONE_ID --cli-input-json "$INPUT_JSON_A" --region ${REGION}
    ARPA_IP_DEL=$(aws route53 list-resource-record-sets --hosted-zone-id $DNS_ZONE_REV_ID --output text |grep -B 1 ${SERVER_VIRT_FQDN} |awk '{print $2;exit}')
    if [ -n "$ARPA_IP_DEL" ]; then
        log "INFO : Delete arpa reverse IP record ${ARPA_IP_DEL}"
        INPUT_JSON_PTR_DEL=$( cat ${SCRIPTS_DIR}/ptr-record-route53.json | sed "s/ARPA-ADR/$ARPA_IP_DEL/;s/UPSERT/DELETE/")
        aws route53 change-resource-record-sets --hosted-zone-id $DNS_ZONE_REV_ID --cli-input-json "$INPUT_JSON_PTR_DEL" --region ${REGION}
    fi
    ARPA_IP=$(echo $SEC_IP| awk -F. '{print $4"."$3"."$2"."$1".in-addr.arpa"}')
    log "INFO : Create new arpa reverse IP record ${ARPA_IP}"
    INPUT_JSON_PTR=$( cat ${SCRIPTS_DIR}/ptr-record-route53.json | sed "s/ARPA-ADR/$ARPA_IP/" )
    aws route53 change-resource-record-sets --hosted-zone-id $DNS_ZONE_REV_ID --cli-input-json "$INPUT_JSON_PTR" --region ${REGION}

    #update VIP in hosts file to avoid DNS TTL wait time
    VIRT_SHORT=$(echo ${SERVER_VIRT_FQDN}|awk -F. '{print $1}')
    sed -i "/${SERVER_VIRT_FQDN}/d" /etc/hosts
    echo ${SEC_IP} ${SERVER_VIRT_FQDN} ${VIRT_SHORT} >> /etc/hosts
    echo -e "\n" >> /etc/hosts
    
}

## Restore
restore() {

    log "INFO: Starting restore procedure"

    ##Get the volume-ids of sybase volumes relevant for snapshot from parameter list
    OIFS=$IFS;
    IFS=",";
    DATAVOL=$(aws ssm get-parameters --names ${SSMPARAMDATAVOL} --region ${REGION} | jq -r ".Parameters[] | .Value")
    DATAVOLID=($DATAVOL);
    for ((i=0; i<${#DATAVOLID[@]}; ++i)); do     echo "DataVolume-ID-$i: ${DATAVOLID[$i]}"; done
    IFS=$OIFS;
    #Log Volumes
    OIFS=$IFS;
    IFS=",";
    LOGVOL=$(aws ssm get-parameters --names ${SSMPARAMLOGVOL} --region ${REGION} | jq -r ".Parameters[] | .Value")
    LOGVOLID=($LOGVOL);
    for ((i=0; i<${#LOGVOLID[@]}; ++i)); do     echo "LogVolume-ID-$i: ${LOGVOLID[$i]}"; done
    IFS=$OIFS;

    ##Get the date of the latest complete snapshot for each volume
    for ((i=0; i<${#DATAVOLID[@]}; ++i));
    do
        LATESTSNAPDATEDATA[$i]=$(aws ec2 describe-snapshots --region $REGION --filters Name=volume-id,Values=${DATAVOLID[$i]} Name=status,Values=completed Name=tag:Createdby,Values=AWS-ASE-Snapshot_of_${HOSTNAME} | jq -r ".Snapshots[] | .StartTime" | sort -r | awk 'NR ==1')
        echo -e "Latest date of snapshot for ${DATAVOLID[$i]} : ${LATESTSNAPDATEDATA[$i]}"
    done
    # Log volume
    for ((i=0; i<${#LOGVOLID[@]}; ++i));
    do
        LATESTSNAPDATELOG[$i]=$(aws ec2 describe-snapshots --region $REGION --filters Name=volume-id,Values=${LOGVOLID[$i]} Name=status,Values=completed Name=tag:Createdby,Values=AWS-ASE-Snapshot_of_${HOSTNAME} | jq -r ".Snapshots[] | .StartTime" | sort -r | awk 'NR ==1')
        echo -e "Latest date of snapshot for ${LOGVOLID[$i]} : ${LATESTSNAPDATELOG[$i]}"
    done

    ##Get the snapshot-id from the latest snapshot
    for ((i=0; i<${#LATESTSNAPDATEDATA[@]}; ++i));
    do
      SNAPIDDATA[$i]=$(aws ec2 describe-snapshots --region $REGION --filters Name=start-time,Values=${LATESTSNAPDATEDATA[$i]} Name=volume-id,Values=${DATAVOLID[$i]} | jq -r ".Snapshots[].SnapshotId")
      echo -e "Snapshot ID: ${SNAPIDDATA[$i]}"
    done
    # Log volume
    for ((i=0; i<${#LATESTSNAPDATELOG[@]}; ++i));
    do
      SNAPIDLOG[$i]=$(aws ec2 describe-snapshots --region $REGION --filters Name=start-time,Values=${LATESTSNAPDATELOG[$i]} Name=volume-id,Values=${LOGVOLID[$i]} | jq -r ".Snapshots[].SnapshotId")
      echo -e "Snapshot ID: ${SNAPIDLOG[$i]}"
    done

    #Get timestamp for log recovery
    TIMESTAMP_LAST_SNAP=$(echo $LATESTSNAPDATEDATA[0] |awk -F "T" '{print $1}' |awk -F "-" '{print $1 $2 $3}')
    log "Snapshot timestamp: ${TIMESTAMP_LAST_SNAP}"


    ##Create new volumes out of snapshot
    for ((i=0; i<${#SNAPIDDATA[@]}; i++));
    do
      NEWVOLDATA[$i]=$(aws ec2 create-volume --region $REGION --availability-zone $AZ --snapshot-id ${SNAPIDDATA[$i]} --volume-type gp2 --output=text --query VolumeId)
      echo -e "Volume-id of created volume: ${NEWVOLDATA[$i]}"
      #device info
      DATADEVICEINFO[$i]=$(aws ec2 describe-snapshots --region $REGION --snapshot-id ${SNAPIDDATA[$i]} --output text | grep device_name | awk '{print $3}')
      echo "Device info for ${NEWVOLDATA[$i]} : ${DATADEVICEINFO[$i]}"
    done
    # Log volume
    for ((i=0; i<${#SNAPIDLOG[@]}; i++));
    do
      NEWVOLLOG[$i]=$(aws ec2 create-volume --region $REGION --availability-zone $AZ --snapshot-id ${SNAPIDLOG[$i]} --volume-type gp2 --output=text --query VolumeId)
      echo -e "Volume-id of created volume: ${NEWVOLLOG[$i]}"
      #device info
      LOGDEVICEINFO[$i]=$(aws ec2 describe-snapshots --region $REGION --snapshot-id ${SNAPIDLOG[$i]} --output text | grep device_name | awk '{print $3}')
      echo "Device info for ${NEWVOLLOG[$i]} : ${LOGDEVICEINFO[$i]}"
    done


    ##Check availability of the volume 
    for ((i=0; i<${#NEWVOLDATA[@]}; i++));
    do
      NEWVOLSTATE="unknown"
      until [ $NEWVOLSTATE == "available" ]; do
        NEWVOLSTATE=$(aws ec2 describe-volumes --region $REGION --volume-ids ${NEWVOLDATA[$i]} --query Volumes[].State --output text)
        echo "Status vol ${NEWVOLDATA[$i]}: $NEWVOLSTATE"
        sleep 5
      done
    done
    # Log volume
    for ((i=0; i<${#NEWVOLLOG[@]}; i++));
    do
      NEWVOLSTATE="unknown"
      until [ $NEWVOLSTATE == "available" ]; do
        NEWVOLSTATE=$(aws ec2 describe-volumes --region $REGION --volume-ids ${NEWVOLLOG[$i]} --query Volumes[].State --output text)
        echo "Status vol ${NEWVOLLOG[$i]}: $NEWVOLSTATE"
        sleep 5
      done
    done

    ##Attach volumes to the instance
    #Data volumes
    for ((i=0; i<${#NEWVOLDATA[@]}; i++));
    do
      aws ec2 attach-volume --region $REGION --volume-id ${NEWVOLDATA[$i]} --instance-id $INSTANCEID --device ${DATADEVICEINFO[$i]}
    done
    #Log volumes
    for ((i=0; i<${#NEWVOLLOG[@]}; i++));
    do
      aws ec2 attach-volume --region $REGION --volume-id ${NEWVOLLOG[$i]} --instance-id $INSTANCEID --device ${LOGDEVICEINFO[$i]}
    done

}

##Mount volumes
mount_volumes() {
    sleep 10
    mount -a
    df -h
}

## Update SSM Parameter with new volume-ids
update_ssm_param() {
    log "INFO: Update SSM parameters with new volume-ids"
    voldatassmupdate=$(IFS=, ; echo "${NEWVOLDATA[*]}")
    aws ssm put-parameter --name $SSMPARAMDATAVOL --type StringList --value "$voldatassmupdate" --overwrite --region $REGION
    vollogssmupdate=$(IFS=, ; echo "${NEWVOLLOG[*]}")
    aws ssm put-parameter --name $SSMPARAMLOGVOL --type StringList --value "$vollogssmupdate" --overwrite --region $REGION
 }

## Start ASE DB + backup server 
start_db() {
    log "Start Sybase DB and Backup server"
        ase_configpath=$(sudo -Eu $SYBADM csh -c 'echo ${SYBASE}/${SYBASE_ASE}')
        sudo -u $SYBADM -i $ase_configpath/bin/startserver -f $ase_configpath/install/RUN_${ASE_SERVER}_q
        sudo -u $SYBADM -i $ase_configpath/bin/startserver -f $ase_configpath/install/RUN_${ASE_SERVER}_BS
    sleep 10
}


## Recover logfiles to the most recent state
recover_db() {
    log "Start database recovery"
    for f in `ls ${TRANS_LOG_DIR}/${ASE_SERVER}*`
        do
            TIMESTAMP_FILE=$(echo $f| awk -F "." '{print $3}')        
            if [ ${TIMESTAMP_FILE} -ge ${TIMESTAMP_LAST_SNAP} ]; then
                log "Applying transaction log: ${f}"
                sudo -u $SYBADM -i isql -k${SYBKEYNAME} -w 1024 -X -e -b --retserverror -o apply_log << EOSQL
set nocount on
go
load transaction ${ASE_SERVER} from '${f}'
go 
EOSQL
            fi
        done
   
}


## Open DB for all users 
open_db() {
    log "Open DB for users"
    sudo -u $SYBADM -i isql -k${SYBKEYNAME} -w 1024 -X -e -b --retserverror -o open_db << EOSQL
set nocount on
go
online database ${ASE_SERVER}
online database saptools
go
EOSQL
    if [ $? -ne 0 ]
    then
      log "ERROR: "
      cat ${SYBASE}/open_db >>${logfile}
    return 1
    fi
}

## Trigger Backup 
trigger_backup () {
    log "Start Backup"
    ${SCRIPTS_DIR}/ebs_snapshots_ASE.sh
}


### MAIN ###
### function execution ###

echo "Start: " $(date)
echo -e "\e[91m Check log file $logfile for more information \e[0m"


log "++++++++++ Start of recovery procedure ++++++++++"

# Update local hosts file for new server IP
update_etc_hosts
#Restart SSM agent
restart_ssm
# Attach server virtual IP for the DB
attach_secondary_ip
# Create new EBS volumes from the snapshot and attach them to the EC2 instance
if restore; then :
else log "ERROR: Restore process failed"
   exit 1
fi

# Modify the fstab table and mount filesystems
mount_volumes
# ASE variables only after /sybase/<SID> mount
SYBASE=$(su $SYBADM -c 'echo $SYBASE')
SYBASE_ASE=$(su $SYBADM -c 'echo $SYBASE_ASE')
# Update DNS entries (both normal and reverse) with virtual hostnamer and IP
update_route53
# Update the SSM volume ID parameters for next restore
update_ssm_param
# Start the DB in queisce mode for log recovery
if start_db; then :
else log "ERROR: Database start failed. Please check log files"
   exit 1
fi

# Apply transaction logs
if recover_db; then :
else log "ERROR: Recovery of log files failed. Please check log files"
   exit 1
fi

# Open DB for all users
if open_db; then :
else log "ERROR: Open database failed"
    cat ${SYBASE}/open_db >>${logfile}
  exit 1
fi

# Trigger EBS snapshots backup
if trigger_backup; then :
else log "ERROR: Backup failed - please check log files"
   exit 1
fi


log "INFO: End of recovery procedure"

exit 0