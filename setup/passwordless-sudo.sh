#! /bin/bash

echo -e "$USER ALL=(ALL:ALL) NOPASSWD: ALL\nDefaults:$USER verifypw=any\n" \
| sudo tee "/etc/sudoers.d/dont-prompt-$USER-for-sudo-password" \
|| {
    echo "Could not add passwordless sudo rule for $USER!";
    exit 1;
}

exit 0;
