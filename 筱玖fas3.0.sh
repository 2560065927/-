#!/bin/sh

NAME_TAG=("OpenVPN CLIENT LIST" "ROUTING TABLE" "GLOBAL STATS" "END")
LOG_FILE="/etc/openvpn/openvpn-status.log"

DB='openvpn'
DBADMIN='vpndata'
DBPASSWD='admin'

flow_info_index=0
function IsFlowInfoStatus()
{
	if [ "${1}" == "${NAME_TAG[0]}" ]
	then
		#进入客户端列表，返回[1]
		flow_info_index=1
		return 1
	elif [ "${1}" == "${NAME_TAG[1]}" ] || [ "${1}" == "${NAME_TAG[2]}" ] || [ "${1}" == "${NAME_TAG[3]}" ]
	then
		#进入其他信息，返回结束[0]
		flow_info_index=0
		return 0
	fi

	if [ ${flow_info_index} -lt 1 ]
	then
		#没有进入客户端列表，返回[0]
		return 0
	fi
	
	let "flow_info_index+=1"
	if [ ${flow_info_index} -lt 4 ]
	then
		#进入客户端列表，还没有进入IP列表，返回[1]
		return 1
	fi
	
	
	#进入到IP列表，返回[2]
	return 2;
}

flow_infos=("")
function GetFlowInfo()
{
	OLD_IFS=${IFS}
	IFS=$2
	unset flow_infos
	flow_infos=(${1})
	IFS=${OLD_IFS}
	
	#echo "flow_infos: ${#flow_infos[@]}"
}


function StringSplit()
{
	local OLD_IFS=${IFS}
	IFS=$2
	local array=(${1})
	IFS=${OLD_IFS}
	echo ${array[@]}
}


function UpdateUserFlowToDB()
{
	local common_name=${flow_infos[0]}
	local bytes_received=${flow_infos[2]}
	local bytes_sent=${flow_infos[3]}
	#echo "username: $username received: $received sents: $sents"
	
	local ip_port=(`StringSplit ${flow_infos[1]} ':'`)
	local trusted_ip=${ip_port[0]}
	local trusted_port=${ip_port[1]}
	#echo "ip: $trusted_ip port: $trusted_port"
	
	#更新日志
	mysql -u$DBADMIN -p$DBPASSWD -e "UPDATE log SET end_time=now(),bytes_received=$bytes_received,bytes_sent=$bytes_sent WHERE trusted_ip='$trusted_ip' AND trusted_port=$trusted_port AND username='$common_name' AND status=1" $DB

	#统计流量
	mysql -u$DBADMIN -p$DBPASSWD -e "UPDATE user SET active=0 WHERE user.username IN (SELECT username FROM (SELECT log.username AS username, quota_bytes FROM user, log WHERE log.username='$common_name' AND log.username=user.username AND TO_DAYS(NOW())-TO_DAYS(start_time)<=quota_cycle GROUP BY log.username HAVING SUM(bytes_received)+SUM(bytes_sent)>=quota_bytes) AS u);" $DB
	
	#判断用户是否被禁用或过期
	mysql -u$DBADMIN -p$DBPASSWD -e "UPDATE user SET active=0 WHERE username='$common_name' AND (enabled=0 or UNIX_TIMESTAMP(now())>UNIX_TIMESTAMP(expired_time));" $DB
	
	local SQL="SELECT COUNT(*) FROM user WHERE username='$common_name' AND active=0"
	local COUNT=($(mysql -u$DBADMIN -p$DBPASSWD -e "$SQL" $DB))
	if [ ${COUNT[1]} -ne 0 ]
	then
		(sleep 1
		echo kill $common_name
		sleep 1)|telnet localhost 7505
	fi
}


#判断用户是否过期
#mysql -u$DBADMIN -p$DBPASSWD -e "UPDATE user SET enabled=0 WHERE UNIX_TIMESTAMP(now())>UNIX_TIMESTAMP(expired_time);" $DB

while read LOG_FILE; do
	
	IsFlowInfoStatus "${LOG_FILE}"
	status=$?
	#echo "output: ${status}"
	if [ ${status} -eq 2 ]
	then
		
		GetFlowInfo "${LOG_FILE}" ","
		if [ ${#flow_infos[@]} -ne 5 ]
		then
			continue
		fi
		
		UpdateUserFlowToDB
	fi
	
done < ${LOG_FILE}