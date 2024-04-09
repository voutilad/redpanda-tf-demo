#!/bin/sh
SUPERUSER_FILE=superusers.txt

if [ -e "${SUPERUSER_FILE}" ]; then
    echo "${SUPERUSER_FILE} already exists. Delete if you want to regenerate."
    exit 1
fi

# generate a passprhase
PASSPHRASE="$(./passphrase/generate.sh | tr -d '\n')"

cat << EOF > "${SUPERUSER_FILE}"
admin:${PASSPHRASE}:SCRAM-SHA-256
EOF

echo "new superuser.txt generated using passphrase: ${PASSPHRASE}"