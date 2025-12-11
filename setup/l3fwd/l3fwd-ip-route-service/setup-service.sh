#! /bin/bash

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

L3FWD_IP_ROUTE_SERVICE_FILE="/etc/systemd/system/l3fwd-ip-route.service"
if [[ -f "$L3FWD_IP_ROUTE_SERVICE_FILE" ]]; then
    echo "l3fwd-ip-route.service already exists. Exiting."
    exit 0;
fi
# move the service file to it's new destination
sudo cp "$SCRIPT_DIR"/l3fwd-ip-route.service /etc/systemd/system/ || {
    echo "Failed to copy l3fwd-ip-route.service to /etc/systemd/system/."
    exit 1;
}

# set the permissions on the service file
sudo chmod =r /etc/systemd/system/l3fwd-ip-route.service || {
    echo "Failed to set permissions on l3fwd-ip-route.service."
    exit 1;
}
# reload after creating the service file
sudo systemctl daemon-reload \
&& sudo systemctl enable l3fwd-ip-route.service \
&& sudo systemctl start l3fwd-ip-route.service \
&& sudo systemctl status l3fwd-ip-route.service \
|| {
    echo "Failed to enable or start l3fwd-ip-route.service. Check the logs for more details."
    exit 1;
}

echo "Succesfully created and started l3fwd-ip-route.service."

exit 0;
