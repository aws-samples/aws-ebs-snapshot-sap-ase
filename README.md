## AWS Snapshots for SAP ASE
How to use AWS EBS Snapshots for SAP ASE to backup the database and to create an automated recovery procedure. More information see [SAP on AWS blog](https://aws.amazon.com/blogs/awsforsap/how-to-use-snapshots-to-create-an-automated-recovery-procedure-for-sap-ase-databases/).

## Backup

### Prerequisites
- SAP ASE version 16.0 SP03 PL08 (min)
- min SLES12 SP4 (tested on SLES 15 SP1)
- SAP ASE volumes are using lvm (log and sapdata on different logical volume groups)
- jq package installed on SAP ASE database host
- AWS CLI installed on SAP ASE databse host (min version: aws-cli/1.18.57 or higher)
- Parameter in AWS SSM parameter store for SAP ASE volumes
- Password for sapsa set in aseuserstore
- SAP ASE virtual hostname and IP is set for the DB as secondary IP on the server (Adaptive Computing enabled)
- EC2 instance requires IAM role with following permissions
	* Amazon EC2 create, describe and delete EBS snapshot
	* Amazon EC2 create tags
	* Amazon EC2 create, attach and dettach volumes
	* Amazon Route 53 add, modify and delete DNS entries
	* Add, delete and update Amazon SSM Parameter Store


### Setup
1) Install SAP ASE using SWPM as distributed SID installation.

2) Install jq package on the SAP ASE server

3) Configure the SAP ASE backup dumps to /backup_efs EFS file SYSTEM

**Database dump**

````
isql -S<SID> -U<user> -X -P<Password>
````
````
use master
````
````
exec sp_config_dump @config_name='<SID>DB', @stripe_dir = '<SID-DB-directory>' , @compression = '101' , @verify = 'header'
````
**Transactional log**

````	
exec sp_config_dump @config_name='<SID>DBLOG', @stripe_dir = '/backup-efs/<SID-log-directory>' , @compression = '101' , @verify = 'header'
````

4) Schedule regular SAP ASE auto backups in SAP DBA cockpit or using crontab. Recommended by SAP to configure the threshold (fill level) if the log segment will be reached

5) Create parameters in AWS System Manager Parameter Store for SAP ASE data and log volumes


````
aws ssm put-parameter --name <sybase-datavol> --type StringList --value vol-1234,vol-5678,vol-9101112
aws ssm put-parameter --name <sybase-logvol> --type StringList --value vol-13141516,vol-17181920
````

6) Create an entry in the ASE aseuserstore (as sidadm) to connect to SAP ASE SID databse with user sapsa
````
aseuserstore -V set <entry_name> <SID> sapsa <password>
````

7) Modify the SAP ASE startup script to start SAP ASE in quescie mode.
This is important, for roll forward SAP ASE recovery in restore script.

````
su - syb<sid>
cp $SYBASE/$SYBASE_ASE/install/RUN_<SID> $SYBASE/$SYBASE_ASE/install/RUN_<SID>_q
````

Add the following line at the end of the file RUN\_\<SERVER>\_q located in the directory $SYBASE/$SYBASE_ASE/install: 

````
-q \
````

### Recommendations
- Recommended frequency: 1 snapshot every 8-12 hours (the frequency of the snapshots, does not impact the RPO, as log backups are written to EFS storage and used during recovery)


### Execute snapshot script:

````
./aws-sap-ase-snapshot.sh

````


## Recovery

### Prerequisites

1. Modify SAP ASE mount points  
Copy the /etc/fstab to /etc/fstab.orig. Modify the /etc/fstab file to remove out the mount points for /sybase/<DBSID> directories. This will ensure the server will boot after re-creation from AMI until the EBS snapshot restore automation will not complete

2. Create AMI of SAP ASE server

(Optional step if used in Auto Scaling Group) 

3. Create Launch template and past the recovery script into the "User data" under "Advanced Details" section

(Optional step if used in Auto Scaling Group) 4. Create an Autoscaling Group with min/max capacity = 1

5. Attach the IAM role described in prerequisites section

## Additional documentation
1. [IAM example policies - Working with snapshots](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ExamplePolicies_EC2.html#iam-example-manage-snapshots)
2. [Restricting access to Systems Manager parameters using IAM policies](https://docs.aws.amazon.com/systems-manager/latest/userguide/sysman-paramstore-access.html)
3. [Attach or Detach Volumes to an EC2 Instance](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_examples_ec2_volumes-instance.html)
4. [How do I create an IAM policy to control access to Amazon EC2 resources using tags?](https://aws.amazon.com/premiumsupport/knowledge-center/iam-ec2-resource-tags)
5. [Using identity-based policies (IAM policies) for Amazon Route 53](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/access-control-managing-permissions.html)
6. [1801984 - SYB: Automated management of long running transactions](https://launchpad.support.sap.com/#/notes/1801984)
7. [1887068 - SYB: Using external backup and restore with SAP ASE](https://launchpad.support.sap.com/#/notes/1887068)

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This library is licensed under the MIT-0 License. See the LICENSE file.

