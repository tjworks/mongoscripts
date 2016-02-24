## Secure your MongoDB cluster with X.509 

### DISCLAIMER
The following article is intended for test environment. 

## Overview
In this tutorial, I will be describing the detailed process of setting up X.509 based authentication, both for cluster inter-member authentication as well as for client  authentication, using a local CA(Certificate Authority).

First we need to understand the distinction between member authentication and client authentication.  MongoDB is a distributed database and deployments almost always consist of multiple mongod or mongos processes running on multiple machines.  Member authentication refers to the fact that these machines need to verify each other to ensure a node attempting to replicate data is indeed part of the current cluster. 

On the other hand, client authentication refers to those MongoDB clients, including mongo shell, export/import tools and  MongoDB drivers.

For member authentication, MongoDB supports keyFiles and X.509 based mechanism. The latter is more secure in a sense that each machine would need a dedicated key to join the cluster. So stealing an existing key from another machine isn't going to be very helpful for those with evil agenda. 

For simplicity, I am going to use one machine and running multiple mongod on different ports for this exercise.  

For the impatient readers like myself, I decided to put the steps into an executable script. This way we can quickly get things working then come back to study the details, with that you can then apply the knowledge in your real environment. 

## Preparation
* One server running linux, I used RedHat 7 but it should work with other flavors as well
* Download  MongoDB Enterprise 3.2: https://www.mongodb.com/download-center#enterprise
* Install MongoDB following instructions documented here: https://docs.mongodb.org/manual/tutorial/install-mongodb-enterprise-on-linux/
* Download the demo shell script and save to clean directory: https://raw.githubusercontent.com/tjworks/mongoscripts/master/x509/setup-x509.sh


Note that you *must* download the Enterprise edition in order to enable X.509 authentication.

## Running the script
Before you run the script, double check:

* Make sure you have MongoDB Enterprise installed. 
* Make sure mongod/mongo are in the executable path
* Make sure no mongod running on 27017 port, or change the port numbers in the shell script


To run the script, go to the directory that contains the script and execute following:

		# chmod +x setup-x509.sh
		# ./setup-x509.sh

If everything goes smoothly, you should have a 3 nodes replicaset running using X.509 as member auth. It will also allow you to connect to the replicaset using mongo shell with the client certificate just generated(in current directory): 
 
	 mongo --ssl --sslPEMKeyFile client1.pem --sslCAFile root-ca.pem --sslAllowInvalidHostnames 

Note above step just allows you to connect to the MongoDB shell. You will not have any permission at this point. To do anything meaningful, you need to  authenticate yourself using following command:

	
	> db.getSiblingDB("$external").auth(
	  {
	    mechanism: "MONGODB-X509",
	    user: "CN=client1,OU=MyClients,O=MongoDB China,L=Shenzhen,ST=GD,C=CN"
	  }
	);
	> db.test.find()

If you are able to execute the last find statement, congratulations, the X.509 authentication is at work! 

Now it's time to perform an anatomy of the script to understand what are the  key tasks involved setting up the authentication mechanism.


## Main Parts of the Script

* Initialization
* Create locale CA & signing keys
* Generate & sign server certificates for member authentication
* Generate & sign client certificates for client authentication
* Start MongoDB cluster in non-auth mode 
* Setup replicaset and initial users
* Start MongoDB cluster using server certificates
* Connect to MongoDB using client certificate

### 0. Some initialization
First initialize some variables. Feel free to modify the values as appropriate. 
 
	dn_prefix="/C=CN/ST=GD/L=Shenzhen/O=MongoDB China"
	ou_member="MyServers"
	ou_client="MyClients"
	mongodb_server_hosts=( "server1" "server2" "server3" )
	mongodb_client_hosts=( "client1" "client2" )
	mongodb_port=27017

Here *dn_prefix* will be used to construct the full DN name for each of the certificate.  *ou_member* is used to have a different OU than the client certificates. Client certificates uses *ou_client* in its OU name. 

*mongodb_server_hosts* should list the hostname(FQDN) for all the MongoDB servers while *mongodb_client_hosts* should list the hostnames for all hthe client machines.

  
For a clean start, lets kill the running mongods and clean up the working directory

	kill $(ps -ef | grep mongod | grep set509 | awk '{print $2}')
	rm -Rf db/*
	mkdir -p db

### 1. Create local root CA

A root CA(Certificate Authority) is  at the top of the certificate chain.  This is the ultimate source of the trust. 

Ideally a third party CA should be used. However in the case of an isolated network, or for testing purpose, we need to use local CA to test the functionality. 
	
	echo "##### STEP 1: Generate root CA "
	openssl genrsa -out root-ca.key 2048
	# !!! In production you will want to password protect the keys
	# openssl genrsa -aes256 -out root-ca.key 2048

	openssl req -new -x509 -days 3650 -key root-ca.key -out root-ca.crt -subj "$dn_prefix/CN=ROOTCA"

	mkdir -p RootCA/ca.db.certs
	echo "01" >> RootCA/ca.db.serial
	touch RootCA/ca.db.index
	echo $RANDOM >> RootCA/ca.db.rand
	mv root-ca* RootCA/
	
Above we first created a key pair *root-ca.key*  with AES256 encryption and 2048 bits strength.  Then using *openssl req* command to generate a self-signed certificate with a validity of 3650 days.   One thing to call out here is the argument **-x509** which tells openssl to self sign the certificate instead of generating a signing request(as what we will do below). The output is a *crt* file,  a certificate contains the public key of the root CA.

### 2:  Create CA config

A CA config file is used to provide some default settings during the certificate signing process, such as the directories to store the certificates etc.  You may change the defaults in *root-ca.cfg* file after it is generated or simply change them within the script. 

	echo "##### STEP 2: Create CA config"
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

### 3. Generate the signing key
Root CA created above is typically not used for actual signing. For signing we need to deligate to so-called Subordinate Authority or Signing CA. In essence, a singing CA is just another certificate that is signed by the root CA. 

	echo "##### STEP 3: Generate signing key"
	openssl genrsa -out signing-ca.key 2048
	# again you would want to password protect your signing key:
	# openssl genrsa -aes256 -out signing-ca.key 2048

	openssl req -new -days 1460 -key signing-ca.key -out signing-ca.csr -subj "$dn_prefix/CN=CA-SIGNER"
	openssl ca -batch -name RootCA -config root-ca.cfg -extensions v3_ca -out signing-ca.crt -infiles signing-ca.csr 

	mkdir -p SigningCA/ca.db.certs
	echo "01" >> SigningCA/ca.db.serial
	touch SigningCA/ca.db.index
	# Should use a better source of random here..
	echo $RANDOM >> SigningCA/ca.db.rand
	mv signing-ca* SigningCA/

We then concatenate all the signing certificates to form a single pem file, this file will be supplied to our mongod or client process later as the value of *sslCAFile* parameter.

	# Create root-ca.pem
	cat RootCA/root-ca.crt SigningCA/signing-ca.crt > root-ca.pem

With the root CA and signing CA setup, now we're ready to sign the certificates used in MongoDB setup. 

###  4. Generate & Sign server certificates 
As we mentioned in the beginning, we need to separate the server certs from client certs, for the purpose of permission control. 

Server certificates are intended for mongod & mongos processes. They're used for inter-member authentication. 


	echo "##### STEP 4: Create server certificates"	
	# Pay attention to the OU part of the subject in "openssl req" command
	for host in "${mongodb_server_hosts[@]}"; do
		echo "Generating key for $host"
	  	openssl genrsa  -out ${host}.key 2048
		openssl req -new -days 365 -key ${host}.key -out ${host}.csr -subj "$dn_prefix/OU=$ou_member/CN=${host}"
		openssl ca -batch -name SigningCA -config root-ca.cfg -out ${host}.crt -infiles ${host}.csr
		cat ${host}.crt ${host}.key > ${host}.pem	
	done 

Above script is in a for loop to generate multiple certificates. Essentially 3 steps are involved with each certificate:
- Use **openssl genrsa** command to create a new key pair
- Use **openssl req** command to generate a signing request for the key
- Use **openssl ca** command to sign the key and output a certificate, using the SigningCA we created earlier. 

Notice the variable *$ou_member*. This signifies the major difference between server certificates and client certificates. Server & client certs must differ in Distinguished Names, or in another word, must differ at least in O, OU or DC.


### 5. Generate & Sign client certificates
These certificates are used by clients, such as mongo shell, mongodump, Java/python/C# drivers etc to connect to MongoDB cluster. 
	
This step is essentially same as step 4 except for the use of   **$ou_client**. This will make the combination of the DC/OU/O for these certificates will be different from the server certs above.

	echo "##### STEP 5: Create client certificates"
	# Pay attention to the OU part of the subject in "openssl req" command
	for host in "${mongodb_client_hosts[@]}"; do
		echo "Generating key for $host"
	  	openssl genrsa  -out ${host}.key 2048
		openssl req -new -days 365 -key ${host}.key -out ${host}.csr -subj "$dn_prefix/OU=$ou_client/CN=${host}"
		openssl ca -batch -name SigningCA -config root-ca.cfg -out ${host}.crt -infiles ${host}.csr
		cat ${host}.crt ${host}.key > ${host}.pem
	done 


### 6. Bring up replicaset in non-auth mode
MongoDB does not create a default root/admin user when enabling authentication, this is no exception to X.509 mode.  The typical procedure is  create the initial admin user first then enable the authentication.   Otherwise once we enable authentication, we won't be able to log in without a valid username. 

Here we're starting a replicaset in non-auth mode. 

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

Now replicaset is up, we need to initialize the replicaset and add user

### 7. Initialize replicaset & add initial user
When using X.509 client authentication, each client must have an user created in MongoDB & granted with proper permission. The username must be same as the client's DN (Distinguished Name), which can be obtained by running an openssl command:

	# obtain the subject from the client key:
	client_subject=`openssl x509 -in client1.pem -inform PEM -subject -nameopt RFC2253 | grep subject | awk '{sub("subject= ",""); print}'`

This would obtain something like: 

	CN=client1,OU=MyClients,O=MongoDB China,L=Shenzhen,ST=GD,C=CN

Obviously it's not mandatory to use the openssl command. It's fairly straightforward to deduce the subject string by concatenating the relevant parts of the DN as shown above. 
	
Once we have the DN name, let's initialize the replicaset and add user:

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
	mongo localhost:$mongodb_port setup_auth.js	

Then stop the non-auth replicaset(so that we can restart later):

	kill $(ps -ef | grep mongod | grep set509 | awk '{print $2}')
	sleep 3

### 8. Restart replicaset in x.509 mode
In real production, you will need to copy each of the certificate/key file to its corresponding host before we can start the cluster in X.509 mode. In this tutorial since we're all doing it on localhost, we can skip the copying. 

Start all 3 nodes, note we added following arguments:

* *sslMode*
* *clusterAuthMode*
* *sslCAFile*: Root CA file we created in step 2, contains the certificates of trusted CAs
* *sslPEMKeyFile*: The specific certificate file for this host/process
* *sslClusterFile*: Can be same as sslPEMKeyFile
* *sslAllowInvalidHostnames*: Only used for testing, allow invalid hostnames
 
You can refer to MongoDB documentation for the details of other arguments.

	echo "##### STEP 8: Restart replicaset in x.509 mode"
	mport=$mongodb_port
	for host in "${mongodb_server_hosts[@]}"; do
		echo "Starting server $host"	
		mongod --replSet set509 --port $mport --dbpath ./db/$host \
			--sslMode requireSSL --clusterAuthMode x509 --sslCAFile root-ca.pem \
			--sslAllowInvalidHostnames --fork --logpath ./db/${host}.log \
			--sslPEMKeyFile ${host}.pem --sslClusterFile ${host}.pem
		let "mport++"
	done 

### 9. Test the connection by using certificate to connect to the replicaset
In order to connect to the mongod using certificate, you must do two things:

-  Supply a client certificate using *--sslPEMKeyFile* option to specify 
-  Supply the root-ca key file using *--sslCAFile* option
-  *--sslAllowInvalidHostnames* is only needed because I'm using one machine. In production you shouldn't need this option

		echo "##### STEP 9: Connecting to replicaset using certificate\n"
		cat > do_login.js <<EOF
		db.getSiblingDB("\$external").auth(
		  {
		    mechanism: "MONGODB-X509",
		    user: "$client_subject"
		  }
		)
		EOF
		
		mongo --ssl --sslPEMKeyFile client1.pem --sslCAFile root-ca.pem --sslAllowInvalidHostnames --shell do_login.js


## Adding new certificate for member or client
If you need to add new nodes to the cluster or to add a new client machine, you just need to follow the steps described in section 5 & section 6 respectively. But in essence following are the steps necessary to create new signed certificate for authentication:

	# substitute variables with actual value: $host, $dn_prefix, $ou_client
	openssl genrsa  -out ${host}.key 2048
	openssl req -new -days 365 -key ${host}.key -out ${host}.csr -subj "$dn_prefix/OU=$ou_client/CN=${host}"
	openssl ca -batch -name SigningCA -config root-ca.cfg -out ${host}.crt -infiles ${host}.csr
	cat ${host}.crt ${host}.key > ${host}.pem

## References:
https://docs.mongodb.org/manual/tutorial/configure-x509-client-authentication/
http://www.allanbank.com/blog/security/tls/x.509/2014/10/13/tls-x509-and-mongodb/
http://www.zytrax.com/tech/survival/ssl.html



