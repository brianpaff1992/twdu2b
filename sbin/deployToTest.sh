#!/usr/bin/env bash

set -xe
export TRAINING_COHORT=gcube
echo "====Updating SSH Config===="


echo "
	User ec2-user
	IdentitiesOnly yes
	ForwardAgent yes
	DynamicForward 6789

Host emr-master.$TRAINING_COHORT.training
    User hadoop

Host *.gcube.training !bastion.gcube.training
    User ec2-user
    ForwardAgent yes
    ProxyCommand ssh bastion.gcube.training -W %h:%p 2>/dev/null

Host bastion.gcube.training
    User ec2-user
    HostName 13.232.117.128
    DynamicForward 6789

" >> ~/.ssh/config

echo "====SSH Config Updated===="

echo "====Insert app config in zookeeper===="
ls -al ~/.ssh/config
ssh-keyscan -H 13.232.117.128 >> ~/.ssh/known_hosts
scp -o StrictHostKeyChecking=no ./zookeeper/seed.sh kafka.$TRAINING_COHORT.training:/tmp/zookeeper-seed.sh
ssh kafka.$TRAINING_COHORT.training '
set -e
export hdfs_server="emr-master.gcube.training:8020"
export kafka_server="kafka.gcube.training:9092"
export zk_command="zookeeper-shell localhost:2181"
sh /tmp/zookeeper-seed.sh
'
echo "====Inserted app config in zookeeper===="

echo "====Copy jar to ingester server===="
scp -o StrictHostKeyChecking=no CitibikeApiProducer/build/libs/free2wheelers-citibike-apis-producer0.1.0.jar ingester.$TRAINING_COHORT.training:/tmp/
echo "====Jar copied to ingester server===="

ssh ingester.$TRAINING_COHORT.training '
set -e

function kill_process {
    query=$1
    pid=`ps aux | grep $query | grep -v "grep" |  awk "{print \\$2}"`

    if [ -z "$pid" ];
    then
        echo "no ${query} process running"
    else
        kill -9 $pid
    fi
}

station_information="station-information"
station_status="station-status"
station_san_francisco="station-san-francisco"


echo "====Kill running producers===="

kill_process ${station_information}
kill_process ${station_status}
kill_process ${station_san_francisco}

echo "====Runing Producers Killed===="

echo "====Deploy Producers===="

nohup java -jar /tmp/free2wheelers-citibike-apis-producer0.1.0.jar --spring.profiles.active=${station_information} --kafka.brokers=kafka.gcube.training:9092 1>/tmp/${station_information}.log 2>/tmp/${station_information}.error.log &
nohup java -jar /tmp/free2wheelers-citibike-apis-producer0.1.0.jar --spring.profiles.active=${station_san_francisco} --producer.topic=station_data_sf --kafka.brokers=kafka.gcube.training:9092 1>/tmp/${station_san_francisco}.log 2>/tmp/${station_san_francisco}.error.log &
nohup java -jar /tmp/free2wheelers-citibike-apis-producer0.1.0.jar --spring.profiles.active=${station_status} --kafka.brokers=kafka.gcube.training:9092 1>/tmp/${station_status}.log 2>/tmp/${station_status}.error.log &

echo "====Producers Deployed===="
'


echo "====Configure HDFS paths===="
scp -o StrictHostKeyChecking=no ./hdfs/seed.sh emr-master.$TRAINING_COHORT.training:/tmp/hdfs-seed.sh

ssh emr-master.$TRAINING_COHORT.training '
set -e
export hdfs_server="emr-master.gcube.training:8020"
export hadoop_path="hadoop"
sh /tmp/hdfs-seed.sh
'

echo "====HDFS paths configured==="


echo "====Copy Raw Data Saver Jar to EMR===="
scp RawDataSaver/target/scala-2.11/free2wheelers-raw-data-saver_2.11-0.0.1.jar emr-master.$TRAINING_COHORT.training:/tmp/
echo "====Raw Data Saver Jar Copied to EMR===="

scp sbin/go.sh emr-master.$TRAINING_COHORT.training:/tmp/go.sh

ssh emr-master.$TRAINING_COHORT.training '
set -e

source /tmp/go.sh

echo "====Kill Old Raw Data Saver===="

kill_application "StationStatusSaverApp"
kill_application "StationInformationSaverApp"
kill_application "StationDataSFSaverApp"

echo "====Old Raw Data Saver Killed===="

echo "====Deploy Raw Data Saver===="

nohup spark-submit --master yarn --deploy-mode cluster --class com.free2wheelers.apps.StationLocationApp --name StationStatusSaverApp --packages org.apache.spark:spark-sql-kafka-0-10_2.11:2.3.0 --driver-memory 500M --conf spark.executor.memory=2g --conf spark.cores.max=1 /tmp/free2wheelers-raw-data-saver_2.11-0.0.1.jar kafka.gcube.training:2181 "/free2wheelers/stationStatus" 1>/tmp/raw-station-status-data-saver.log 2>/tmp/raw-station-status-data-saver.error.log &

nohup spark-submit --master yarn --deploy-mode cluster --class com.free2wheelers.apps.StationLocationApp --name StationInformationSaverApp --packages org.apache.spark:spark-sql-kafka-0-10_2.11:2.3.0 --driver-memory 500M --conf spark.executor.memory=2g --conf spark.cores.max=1 /tmp/free2wheelers-raw-data-saver_2.11-0.0.1.jar kafka.gcube.training:2181 "/free2wheelers/stationInformation" 1>/tmp/raw-station-information-data-saver.log 2>/tmp/raw-station-information-data-saver.error.log &

nohup spark-submit --master yarn --deploy-mode cluster --class com.free2wheelers.apps.StationLocationApp --name StationDataSFSaverApp --packages org.apache.spark:spark-sql-kafka-0-10_2.11:2.3.0 --driver-memory 500M --conf spark.executor.memory=2g --conf spark.cores.max=1 /tmp/free2wheelers-raw-data-saver_2.11-0.0.1.jar kafka.gcube.training:2181 "/free2wheelers/stationDataSF" 1>/tmp/raw-station-data-sf-saver.log 2>/tmp/raw-station-data-sf-saver.error.log &

echo "====Raw Data Saver Deployed===="
'

echo "====Copy Monitoring Job Jar and Script to EMR===="
scp Monitoring/target/scala-2.11/free2wheelers-monitoring_2.11-0.0.1.jar emr-master.$TRAINING_COHORT.training:/tmp/
scp Monitoring/src/main/resources/scripts/delivery-file-metric-provider.sh emr-master.$TRAINING_COHORT.training:/tmp/
#scp -o StrictHostKeyChecking=no -r airflow/dags airflow.gcube.training:~/airflow/dags

echo "====Copy Station Consumers Jar to EMR===="
scp StationConsumer/target/scala-2.11/free2wheelers-station-consumer_2.11-0.0.1.jar emr-master.$TRAINING_COHORT.training:/tmp/

echo "====Station Consumers Jar Copied to EMR===="
scp StationTransformerNYC/target/scala-2.11/free2wheelers-station-transformer-nyc_2.11-0.0.1.jar emr-master.$TRAINING_COHORT.training:/tmp/

scp sbin/go.sh emr-master.$TRAINING_COHORT.training:/tmp/go.sh

ssh emr-master.$TRAINING_COHORT.training '
set -e

source /tmp/go.sh

echo "====Schedule Monitoring Job===="
echo whoami
chmod +x /tmp/delivery-file-metric-provider.sh
(crontab -u hadoop -l 2>/dev/null; echo "*/1 * * * * /tmp/delivery-file-metric-provider.sh") | crontab -

echo "====Kill Old Station Consumers===="

kill_application "StationApp"
kill_application "StationTransformerNYC"

echo "====Old Station Consumers Killed===="

echo "====Deploy Station Consumers===="

nohup spark-submit --master yarn --deploy-mode cluster --class com.free2wheelers.apps.StationApp --name StationApp --packages org.apache.spark:spark-sql-kafka-0-10_2.11:2.3.0  --driver-memory 500M --conf spark.executor.memory=2g --conf spark.cores.max=1 /tmp/free2wheelers-station-consumer_2.11-0.0.1.jar kafka.gcube.training:2181 1>/tmp/station-consumer.log 2>/tmp/station-consumer.error.log &

nohup spark-submit --master yarn --deploy-mode cluster --class com.free2wheelers.apps.StationApp --name StationTransformerNYC --packages org.apache.spark:spark-sql-kafka-0-10_2.11:2.3.0  --driver-memory 500M --conf spark.executor.memory=2g --conf spark.cores.max=1 /tmp/free2wheelers-station-transformer-nyc_2.11-0.0.1.jar kafka.gcube.training:2181 1>/tmp/station-transformer-nyc.log 2>/tmp/station-transformer-nyc.error.log &

echo "====Station Consumers Deployed===="
'
