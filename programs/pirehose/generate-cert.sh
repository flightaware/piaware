#!/bin/sh

if [ `piaware-config -show enable-firehose` != "yes" ]
then
    # not enabled, no need for the cert
    exit 0
fi

if [ ! -e /etc/piaware/pirehose.cert.pem ] && [ ! -e /etc/piaware/pirehose.key.pem ]
then
    echo "Generating pirehose self-signed certificate.." >&2
    mkdir -p /etc/piaware
    openssl req -x509 -newkey rsa:4096 -keyout /etc/piaware/pirehose.key.pem -out /etc/piaware/pirehose.cert.pem -days 3650 -nodes -subj /CN=pirehose -batch
    chown root:piaware /etc/piaware/pirehose.key.pem
    chmod 0640 /etc/piaware/pirehose.key.pem
    chmod 0644 /etc/piaware/pirehose.cert.pem
fi
