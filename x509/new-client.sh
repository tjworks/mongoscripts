 
##### Feel free to change following section values ####
# Changing this to include: country, province, city, company
cn_prefix="/C=CN/ST=GD/L=Shenzhen/O=MongoDB China"
ou_member="MyServers"
ou_client="MyClients"
mongodb_server_hosts=( "server1" "server2" "server3" )
mongodb_client_hosts=( "client1" "client2" )
mongodb_port=27017

if [ "$1" = "" ]; then
	echo "Usage: new-client.sh <client-host-name>"
	exit 0
fi
echo "##### : Create client certificates"
# Now create & sign keys for each client
# Pay attention to the OU part of the subject in "openssl req" command
host=$1
echo "Generating key for $host"
openssl genrsa  -out ${host}.key 2048
openssl req -new -days 365 -key ${host}.key -out ${host}.csr -subj "$cn_prefix/OU=$ou_client/CN=${host}"
openssl ca -batch -name SigningCA -config root-ca.cfg -out ${host}.crt -infiles ${host}.csr
cat ${host}.crt ${host}.key > ${host}.pem

# obtain the subject from the client key:
client_subject=`openssl x509 -in ${host}.pem -inform PEM -subject -nameopt RFC2253 | grep subject | awk '{sub("subject= ",""); print}'`

echo "##### : Add new client user"

cat > add_new_user.js <<EOF
db.getSiblingDB("\$external").auth(
  {
    mechanism: "MONGODB-X509",
    user: "CN=client1,OU=MyClients,O=MongoDB China,L=Shenzhen,ST=GD,C=CN"
  }
);
db.getSiblingDB("\$external").runCommand(
  	{
    	createUser: "$client_subject",
    	roles: [
             { role: "readWrite", db: 'test' }
        ],
    	writeConcern: { w: "majority" , wtimeout: 5000 }
  	}
);
print("Added new user $client_subject");
EOF

mongo --ssl --sslPEMKeyFile client1.pem --sslCAFile root-ca.pem --sslAllowInvalidHostnames add_new_user.js

echo "#####  Connecting to replicaset as new user ${host} "
cat > do_login_newclient.js <<EOF
db.getSiblingDB("\$external").auth(
  {
    mechanism: "MONGODB-X509",
    user: "$client_subject"
  }
);
db.getSiblingDB("test").test.insert({a:1});
EOF

mongo --ssl --sslPEMKeyFile ${host}.pem --sslCAFile root-ca.pem --sslAllowInvalidHostnames --shell do_login_newclient.js
