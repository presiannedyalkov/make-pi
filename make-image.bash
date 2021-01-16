#!/bin/bash

# Forked from: https://github.com/kenfallon/fix-ssh-on-pi

# To Do: 
# (v) 1. Make the image name a settings variable.
# (v) 2. Make the settings file a cli parameter and split settings per device.

# parse command line arguments
usage() { echo "Usage: $0 -s settings.ini" 1>&2; exit 1; }

while getopts "s:" o; do
    case "${o}" in
        s)
            settings_file=${OPTARG}
            ;;
        [?])
            usage
		        exit 1
            ;;
    esac
done
shift $((OPTIND-1))

echo "settings_file = ${settings_file}"

if [ ! -e "${settings_file}" ]; then
    usage
fi


if [ -e "${settings_file}" ]
then
  source "${settings_file}"
elif [ -e "${HOME}/${settings_file}" ]
then
  source "${HOME}/${settings_file}"
else
  echo "ERROR: Can't find the Settings file \"${settings_file}\""
  exit 1
fi

variables=(
  root_password_clear
  pi_password_clear
  public_key_file
  wifi_file
  hostname
  image_to_download
  url_base
)

for variable in "${variables[@]}"
do
  if [[ -z ${!variable+x} ]]; then   # indirect expansion here
    echo "ERROR: The variable \"${variable}\" is missing from your \""${settings_file}"\" file.";
    exit 2
  fi
done

# Check how to deal with this for os different than raspios
version="$( wget -q ${url_base} -O - | xmllint --html --xmlout --xpath 'string(/html/body/table/tr[last()-1]/td/a/@href)' - )"
sha_file=$( wget -q ${url_base}/${version} -O - | xmllint --html --xmlout --xpath 'string(/html/body/table/tr/td/a[contains(@href, "256")])' - )
sha_sum=$( wget -q "${url_base}/${version}/${sha_file}" -O - | awk '{print $1}' )
sdcard_mount="/mnt/sdcard"

if [ $(id | grep 'uid=0(root)' | wc -l) -ne "1" ]
then
    echo "You are not root "
    exit
fi

if [ ! -e "${public_key_file}" ]
then
    echo "Can't find the public key file \"${public_key_file}\""
    echo "You can create one using:"
    echo "   ssh-keygen -t ed25519 -f ./${public_key_file} -C \"Raspberry Pi keys\""
    exit 3
fi

function umount_sdcard () {
    umount "${sdcard_mount}"
    if [ $( ls -al "${sdcard_mount}" | wc -l ) -eq "3" ]
    then
        echo "Sucessfully unmounted \"${sdcard_mount}\""
        sync
    else
        echo "Could not unmount \"${sdcard_mount}\""
        exit 4
    fi
}

# Download the latest image, using the  --continue "Continue getting a partially-downloaded file"
wget --continue ${image_to_download} -O image.zip

echo "Checking the SHA-1 of the downloaded image matches \"${sha_sum}\""

if [ $( sha256sum image.zip | grep ${sha_sum} | wc -l ) -eq "1" ]
then
    echo "The sha_sums match"
else
    echo "The sha_sums did not match"
    exit 5
fi

if [ ! -d "${sdcard_mount}" ]
then
  mkdir ${sdcard_mount}
fi

# unzip
extracted_image=$( 7z l image.zip | awk '/-raspios-/ {print $NF}' )
echo "The name of the image is \"${extracted_image}\""

7z x -y image.zip

if [ ! -e ${extracted_image} ]
then
    echo "Can't find the image \"${extracted_image}\""
    exit 6
fi

umount_sdcard
echo "Mounting the sdcard boot disk"

loop_base=$( losetup --partscan --find --show "${extracted_image}" )

echo "Running: mount ${loop_base}p1 \"${sdcard_mount}\" "
mount ${loop_base}p1 "${sdcard_mount}"
ls -al /mnt/sdcard
if [ ! -e "${sdcard_mount}/kernel.img" ]
then
    echo "Can't find the mounted card\"${sdcard_mount}/kernel.img\""
    exit 7
fi

cp -v "${wifi_file}" "${sdcard_mount}/wpa_supplicant.conf"
if [ ! -e "${sdcard_mount}/wpa_supplicant.conf" ]
then
    echo "Can't find the ssh file \"${sdcard_mount}/wpa_supplicant.conf\""
    exit 8
fi

touch "${sdcard_mount}/ssh"
if [ ! -e "${sdcard_mount}/ssh" ]
then
    echo "Can't find the ssh file \"${sdcard_mount}/ssh\""
    exit 9
fi

echo '#!/bin/bash' > "${sdcard_mount}/firstboot.sh"
echo "sed \"s/raspberrypi/${hostname}/g\" -i /etc/hostname /etc/hosts" >> "${sdcard_mount}/firstboot.sh"
if [ -e "${first_boot}" ]
then
  echo "" >> "${sdcard_mount}/firstboot.sh"
  cat "${first_boot}" >> "${sdcard_mount}/firstboot.sh"
fi

umount_sdcard

echo "Mounting the sdcard root disk"
echo "Running: mount ${loop_base}p2 \"${sdcard_mount}\" "
mount ${loop_base}p2 "${sdcard_mount}"
ls -al /mnt/sdcard

if [ ! -e "${sdcard_mount}/etc/shadow" ]
then
    echo "Can't find the mounted card\"${sdcard_mount}/etc/shadow\""
    exit 10
fi

echo "Change the passwords and sshd_config file"

root_password="$( python3 -c "import crypt; print(crypt.crypt('${root_password_clear}', crypt.mksalt(crypt.METHOD_SHA512)))" )"
pi_password="$( python3 -c "import crypt; print(crypt.crypt('${pi_password_clear}', crypt.mksalt(crypt.METHOD_SHA512)))" )"
sed -e "s#^root:[^:]\+:#root:${root_password}:#" "${sdcard_mount}/etc/shadow" -e  "s#^pi:[^:]\+:#pi:${pi_password}:#" -i "${sdcard_mount}/etc/shadow"
sed -e 's;^#PasswordAuthentication.*$;PasswordAuthentication no;g' -e 's;^PermitRootLogin .*$;PermitRootLogin no;g' -i "${sdcard_mount}/etc/ssh/sshd_config"
mkdir "${sdcard_mount}/home/pi/.ssh"
chmod 0700 "${sdcard_mount}/home/pi/.ssh"
chown 1000:1000 "${sdcard_mount}/home/pi/.ssh"
echo ${public_key_file}
cat ${public_key_file} >> "${sdcard_mount}/home/pi/.ssh/authorized_keys"
chown 1000:1000 "${sdcard_mount}/home/pi/.ssh/authorized_keys"
chmod 0600 "${sdcard_mount}/home/pi/.ssh/authorized_keys"

echo "[Unit]
Description=FirstBoot
After=network.target
Before=rc-local.service
ConditionFileNotEmpty=/boot/firstboot.sh

[Service]
ExecStart=/boot/firstboot.sh
ExecStartPost=/bin/mv /boot/firstboot.sh /boot/firstboot.sh.done
Type=oneshot
RemainAfterExit=no

[Install]
WantedBy=multi-user.target" > "${sdcard_mount}/lib/systemd/system/firstboot.service"

cd "${sdcard_mount}/etc/systemd/system/multi-user.target.wants" && ln -s "/lib/systemd/system/firstboot.service" "./firstboot.service"
cd -

umount_sdcard

new_name="${extracted_image%.*}-ssh-enabled.img"
cp -v "${extracted_image}" "${new_name}"

losetup --detach ${loop_base}

lsblk

echo ""
echo "Now you can burn the disk using something like:"
echo "      dd bs=4M status=progress if=${new_name} of=/dev/mmcblk????"
echo ""
