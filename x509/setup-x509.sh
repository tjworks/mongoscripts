
# Prerequisites:
#	a. Make sure you have MongoDB Enterprise installed. 
#   b. Make sure mongod/mongo are in the executable path
#   c. Make sure no mongod running on 27017 port, or change the port below
#   d. Run this script in a clean directory

##### Feel free to change following section values ####
# Changing this to include: country, province, city, company
dn_prefix="/C=CN/ST=GD/L=Shenzhen/O=MongoDB China"
ou_member="MyServers"
ou_client="MyClients"
mongodb_server_hosts=( "server1" "server2" "server3" )
mongodb_client_hosts=( "client1" "client2" )
mongodb_port=27017


# make a subdirectory for mongodb cluster
kill $(ps -ef | grep mongod | grep set509 | awk '{print $2}')
rm -Rf db/*
mkdir -p db

echo "##### STEP 1: Generate root CA "
openssl genrsa -out root-ca.key 2048
# !!! In production you will want to use -aes256 to password protect the keys
# openssl genrsa -aes256 -out root-ca.key 2048

openssl req -new -x509 -days 3650 -key root-ca.key -out root-ca.crt -subj "$dn_prefix/CN=ROOTCA"

mkdir -p RootCA/ca.db.certs
echo "01" >> RootCA/ca.db.serial
touch RootCA/ca.db.index
echo $RANDOM >> RootCA/ca.db.rand
mv root-ca* RootCA/

echo "##### STEP 2: Create CA config"
# Generate CA config
cat >> root-ca.cfg <<EOF
[ RootCA ]
dir             = ./RootCA
certs           = \$dir/ca.db.certs
database        = \$dir/ca.db.index
new_certs_dir   = \$dir/ca.db.certs
certificate     = \$dir/root-ca.crt
serial          = \$dir/ca.db.serial
private_key     = \$dir/root-ca.key
RANDFILE        = \$dir/ca.db.rand
default_md      = sha256
default_days    = 365
default_crl_days= 30
email_in_dn     = no
unique_subject  = no
policy          = policy_match

[ SigningCA ]
dir             = ./SigningCA
certs           = \$dir/ca.db.certs
database        = \$dir/ca.db.index
new_certs_dir   = \$dir/ca.db.certs
certificate     = \$dir/signing-ca.crt
serial          = \$dir/ca.db.serial
private_key     = \$dir/signing-ca.key
RANDFILE        = \$dir/ca.db.rand
default_md      = sha256
default_days    = 365
default_crl_days= 30
email_in_dn     = no
unique_subject  = no
policy          = policy_match
 
[ policy_match ]
countryName     = match
stateOrProvinceName = match
localityName            = match
organizationName    = match
organizationalUnitName  = optional
commonName      = supplied
emailAddress        = optional

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment

[ v3_ca ]
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always,issuer:always
basicConstraints = CA:true
EOF

echo "##### STEP 3: Generate signing key"
# We do not use root key to sign certificate, instead we generate a signing key
openssl genrsa -out signing-ca.key 2048
# !!! In production you will want to use -aes256 to password protect the keys
# openssl genrsa -aes256 -out signing-ca.key 2048

openssl req -new -days 1460 -key signing-ca.key -out signing-ca.csr -subj "$dn_prefix/CN=CA-SIGNER"
openssl ca -batch -name RootCA -config root-ca.cfg -extensions v3_ca -out signing-ca.crt -infiles signing-ca.csr 

mkdir -p SigningCA/ca.db.certs
echo "01" >> SigningCA/ca.db.serial
touch SigningCA/ca.db.index
# Should use a better source of random here..
echo $RANDOM >> SigningCA/ca.db.rand
mv signing-ca* SigningCA/

# Create root-ca.pem
cat RootCA/root-ca.crt SigningCA/signing-ca.crt > root-ca.pem



echo "##### STEP 4: Create server certificates"
# Now create & sign keys for each mongod server 
# Pay attention to the OU part of the subject in "openssl req" command
# You may want to use FQDNs instead of short hostname
for host in "${mongodb_server_hosts[@]}"; do
	echo "Generating key for $host"
  	openssl genrsa  -out ${host}.key 2048
	openssl req -new -days 365 -key ${host}.key -out ${host}.csr -subj "$dn_prefix/OU=$ou_member/CN=${host}"
	openssl ca -batch -name SigningCA -config root-ca.cfg -out ${host}.crt -infiles ${host}.csr
	cat ${host}.crt ${host}.key > ${host}.pem	
done 

echo "##### STEP 5: Create client certificates"
# Now create & sign keys for each client
# Pay attention to the OU part of the subject in "openssl req" command
for host in "${mongodb_client_hosts[@]}"; do
	echo "Generating key for $host"
  	openssl genrsa  -out ${host}.key 2048
	openssl req -new -days 365 -key ${host}.key -out ${host}.csr -subj "$dn_prefix/OU=$ou_client/CN=${host}"
	openssl ca -batch -name SigningCA -config root-ca.cfg -out ${host}.crt -infiles ${host}.csr
	cat ${host}.crt ${host}.key > ${host}.pem
done 

echo ""
echo "##### STEP 6: Start up replicaset in non-auth mode"
mport=$mongodb_port
for host in "${mongodb_server_hosts[@]}"; do
	echo "Starting server $host in non-auth mode"	
	mkdir -p ./db/${host}
	mongod --replSet set509 --port $mport --dbpath ./db/$host \
		--fork --logpath ./db/${host}.log		
	let "mport++"
done 
sleep 3
# obtain the subject from the client key:
client_subject=`openssl x509 -in ${mongodb_client_hosts[0]}.pem -inform PEM -subject -nameopt RFC2253 | grep subject | awk '{sub("subject= ",""); print}'`

echo "##### STEP 7: setup replicaset & initial user role\n"
myhostname=`hostname`
cat > setup_auth.js <<EOF
rs.initiate();
mport=$mongodb_port;
mport++;
rs.add("$myhostname:" + mport);
mport++;
rs.add("$myhostname:" + mport);
sleep(5000);
db.getSiblingDB("\$external").runCommand(
  	{
    	createUser: "$client_subject",
    	roles: [
             { role: "readWrite", db: 'test' },
             { role: "userAdminAnyDatabase", db: "admin" },
             { role: "clusterAdmin", db:"admin"}
           ],
    	writeConcern: { w: "majority" , wtimeout: 5000 }
  	}
);
EOF
cat setup_auth.js
mongo localhost:$mongodb_port setup_auth.js	
kill $(ps -ef | grep mongod | grep set509 | awk '{print $2}')
sleep 3

echo "##### STEP 8: Restart replicaset in x.509 mode\n"
mport=$mongodb_port
for host in "${mongodb_server_hosts[@]}"; do
	echo "Starting server $host"	
	mongod --replSet set509 --port $mport --dbpath ./db/$host \
		--sslMode requireSSL --clusterAuthMode x509 --sslCAFile root-ca.pem \
		--sslAllowInvalidHostnames --fork --logpath ./db/${host}.log \
		--sslPEMKeyFile ${host}.pem --sslClusterFile ${host}.pem
	let "mport++"
done 


echo "##### STEP 9: Connecting to replicaset using certificate\n"
cat > do_login.js <<EOF
db.getSiblingDB("\$external").auth(
  {
    mechanism: "MONGODB-X509",
    user: "$client_subject"
  }
)
EOF

# mongo --ssl --sslPEMKeyFile client1.pem --sslCAFile root-ca.pem --sslAllowInvalidHostnames --shell do_login.js
