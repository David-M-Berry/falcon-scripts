#!/bin/bash

print_usage() {
    cat <<EOF
Installs and configures the CrowdStrike Falcon Sensor for Linux.

The script recognizes the following environmental variables:

Authentication:
    - FALCON_CLIENT_ID                  (default: unset)
        Your CrowdStrike Falcon API client ID.

    - FALCON_CLIENT_SECRET              (default: unset)
        Your CrowdStrike Falcon API client secret.

    - FALCON_ACCESS_TOKEN               (default: unset)
        Your CrowdStrike Falcon API access token.
        If used, FALCON_CLOUD must also be set.

    - FALCON_CLOUD                      (default: unset)
        The cloud region where your CrowdStrike Falcon instance is hosted.
        Required if using FALCON_ACCESS_TOKEN.
        Accepted values are ['us-1', 'us-2', 'eu-1', 'us-gov-1'].

Other Options
    - FALCON_CID                        (default: auto)
        The customer ID that should be associated with the sensor.
        By default, the CID is automatically determined by your authentication credentials.

    - FALCON_SENSOR_VERSION_DECREMENT   (default: 0 [latest])
        The number of versions prior to the latest release to install.

    - FALCON_PROVISIONING_TOKEN         (default: unset)
        The provisioning token to use for installing the sensor.

    - FALCON_SENSOR_UPDATE_POLICY_NAME  (default: unset)
        The name of the sensor update policy to use for installing the sensor.

    - FALCON_TAGS                       (default: unset)
        A comma seperated list of tags for sensor grouping.

    - FALCON_APD                        (default: unset)
        Configures if the proxy should be enabled or disabled.

    - FALCON_APH                        (default: unset)
        The proxy host for the sensor to use when communicating with CrowdStrike.

    - FALCON_APP                        (default: unset)
        The proxy port for the sensor to use when communicating with CrowdStrike.

    - FALCON_BILLING                    (default: default)
        To configure the sensor billing type.
        Accepted values are [default|metered].

    - FALCON_BACKEND                    (default: auto)
        For sensor backend.
        Accepted values are values: [auto|bpf|kernel].

    - FALCON_TRACE                      (default: none)
        To configure the trace level.
        Accepted values are [none|err|warn|info|debug]

    - FALCON_UNINSTALL                  (default: false)
        To uninstall the falcon sensor.
        **LEGACY** Please use the falcon-linux-uninstall.sh script instead.

    - FALCON_INSTALL_ONLY               (default: false)
        To install the falcon sensor without registering it with CrowdStrike.

    - FALCON_DOWNLOAD_ONLY              (default: false)
        To download the falcon sensor without installing it.

    - FALCON_DOWNLOAD_PATH              (default: \$PWD)
        The path to download the falcon sensor to.

    - ALLOW_LEGACY_CURL                 (default: false)
        To use the legacy version of curl; version < 7.55.0.

    - GET_ACCESS_TOKEN                  (default: unset)
        Prints an access token and exits.
        Requires FALCON_CLIENT_ID and FALCON_CLIENT_SECRET.
        Accepted values are ['true', 'false'].

EOF
}

main() {
    if [ -n "$1" ]; then
        print_usage
        exit 1
    fi

    if [ "$GET_ACCESS_TOKEN" = "true" ]; then
        get_oauth_token
        echo "$cs_falcon_oauth_token"
        exit 0
    fi

    if [ "${FALCON_DOWNLOAD_ONLY}" = "true" ]; then
        echo -n 'Downloading Falcon Sensor ... '
        local download_destination
        download_destination=$(cs_sensor_download_only)
        echo '[ Ok ]'
        echo "Falcon Sensor downloaded to: $download_destination"
        exit 0
    fi
    echo -n 'Check if Falcon Sensor is running ... '
    cs_sensor_is_running
    echo '[ Not present ]'
    echo -n 'Falcon Sensor Install  ... '
    cs_sensor_install
    echo '[ Ok ]'
    if [ -z "$FALCON_INSTALL_ONLY" ] || [ "${FALCON_INSTALL_ONLY}" = "false" ]; then
        echo -n 'Falcon Sensor Register ... '
        cs_sensor_register
        echo '[ Ok ]'
        echo -n 'Falcon Sensor Restart  ... '
        cs_sensor_restart
        echo '[ Ok ]'
    fi
    echo 'Falcon Sensor installed successfully.'
}

cs_sensor_register() {
    # Get the falcon cid
    cs_falcon_cid="$(get_falcon_cid)"

    # add the cid to the params
    cs_falcon_args=--cid="${cs_falcon_cid}"
    if [ -n "${cs_falcon_token}" ]; then
        cs_token=--provisioning-token="${cs_falcon_token}"
        cs_falcon_args="$cs_falcon_args $cs_token"
    fi
    # add tags to the params
    if [ -n "${FALCON_TAGS}" ]; then
        cs_falconctl_opt_tags=--tags="$FALCON_TAGS"
        cs_falcon_args="$cs_falcon_args $cs_falconctl_opt_tags"
    fi
    # add proxy enable/disable param
    if [ -n "${cs_falcon_apd}" ]; then
        cs_falconctl_opt_apd=--apd=$cs_falcon_apd
        cs_falcon_args="$cs_falcon_args $cs_falconctl_opt_apd"
    fi
    # add proxy host to the params
    if [ -n "${FALCON_APH}" ]; then
        cs_falconctl_opt_aph=--aph="${FALCON_APH}"
        cs_falcon_args="$cs_falcon_args $cs_falconctl_opt_aph"
    fi
    # add proxy port to the params
    if [ -n "${FALCON_APP}" ]; then
        cs_falconctl_opt_app=--app="${FALCON_APP}"
        cs_falcon_args="$cs_falcon_args $cs_falconctl_opt_app"
    fi
    # add the billing type to the params
    if [ -n "${FALCON_BILLING}" ]; then
        cs_falconctl_opt_billing=--billing="${cs_falcon_billing}"
        cs_falcon_args="$cs_falcon_args $cs_falconctl_opt_billing"
    fi
    # add the backend to the params
    if [ -n "${cs_falcon_backend}" ]; then
        cs_falconctl_opt_backend=--backend="${cs_falcon_backend}"
        cs_falcon_args="$cs_falcon_args $cs_falconctl_opt_backend"
    fi
    # add the trace level to the params
    if [ -n "${cs_falcon_trace}" ]; then
        cs_falconctl_opt_trace=--trace="${cs_falcon_trace}"
        cs_falcon_args="$cs_falcon_args $cs_falconctl_opt_trace"
    fi
    # run the configuration command
    # shellcheck disable=SC2086
    /opt/CrowdStrike/falconctl -s -f ${cs_falcon_args}
}

cs_sensor_is_running() {
    if pgrep -u root falcon-sensor >/dev/null 2>&1; then
        echo "sensor is already running... exiting"
        exit 0
    fi
}

cs_sensor_restart() {
    if type systemctl >/dev/null 2>&1; then
        systemctl restart falcon-sensor
    elif type service >/dev/null 2>&1; then
        service falcon-sensor restart
    else
        die "Could not restart falcon sensor"
    fi
}

cs_sensor_install() {
    local tempdir package_name
    tempdir=$(mktemp -d)

    tempdir_cleanup() { rm -rf "$tempdir"; }
    trap tempdir_cleanup EXIT

    get_oauth_token
    package_name=$(cs_sensor_download "$tempdir")
    os_install_package "$package_name"

    tempdir_cleanup
}

cs_sensor_download_only() {
    local destination_dir

    destination_dir="${FALCON_DOWNLOAD_PATH:-$PWD}"
    get_oauth_token
    cs_sensor_download "$destination_dir"
}

cs_sensor_remove() {
    remove_package() {
        local pkg="$1"

        if type dnf >/dev/null 2>&1; then
            dnf remove -q -y "$pkg" || rpm -e --nodeps "$pkg"
        elif type yum >/dev/null 2>&1; then
            yum remove -q -y "$pkg" || rpm -e --nodeps "$pkg"
        elif type zypper >/dev/null 2>&1; then
            zypper --quiet remove -y "$pkg" || rpm -e --nodeps "$pkg"
        elif type apt >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt purge -y "$pkg" >/dev/null
        else
            rpm -e --nodeps "$pkg"
        fi
    }

    remove_package "falcon-sensor"
}

cs_sensor_policy_version() {
    local cs_policy_name="$1" sensor_update_policy sensor_update_versions

    sensor_update_policy=$(
        curl_command -G "https://$(cs_cloud)/policy/combined/sensor-update/v2" \
            --data-urlencode "filter=platform_name:\"Linux\"+name.raw:\"$cs_policy_name\""
    )

    handle_curl_error $?

    if echo "$sensor_update_policy" | grep "authorization failed"; then
        die "Access denied: Please make sure that your Falcon API credentials allow access to sensor update policies (scope Sensor update policies [read])"
    elif echo "$sensor_update_policy" | grep "invalid bearer token"; then
        die "Invalid Access Token: $cs_falcon_oauth_token"
    fi

    sensor_update_versions=$(echo "$sensor_update_policy" | json_value "sensor_version")
    if [ -z "$sensor_update_versions" ]; then
        die "Could not find a sensor update policy with name: $cs_policy_name"
    fi

    oldIFS=$IFS
    IFS=" "
    # shellcheck disable=SC2086
    set -- $sensor_update_versions
    if [ "$(echo "$sensor_update_versions" | wc -w)" -gt 1 ]; then
        if [ "$cs_os_arch" = "aarch64" ]; then
            echo "$2"
        else
            echo "$1"
        fi
    else
        echo "$1"
    fi
    IFS=$oldIFS
}

cs_sensor_download() {
    local destination_dir="$1" existing_installers sha_list INDEX sha file_type installer

    if [ -n "$cs_sensor_policy_name" ]; then
        cs_sensor_version=$(cs_sensor_policy_version "$cs_sensor_policy_name")
        cs_api_version_filter="+version:\"$cs_sensor_version\""

        if [ "$cs_falcon_sensor_version_dec" -gt 0 ]; then
            echo "WARNING: Disabling FALCON_SENSOR_VERSION_DECREMENT because it conflicts with FALCON_SENSOR_UPDATE_POLICY_NAME"
            cs_falcon_sensor_version_dec=0
        fi
    fi

    existing_installers=$(
        curl_command -G "https://$(cs_cloud)/sensors/combined/installers/v1?sort=version|desc" \
            --data-urlencode "filter=os:\"$cs_os_name\"+os_version:\"*$cs_os_version*\"$cs_api_version_filter$cs_os_arch_filter"
    )

    handle_curl_error $?

    if echo "$existing_installers" | grep "authorization failed"; then
        die "Access denied: Please make sure that your Falcon API credentials allow sensor download (scope Sensor Download [read])"
    elif echo "$existing_installers" | grep "invalid bearer token"; then
        die "Invalid Access Token: $cs_falcon_oauth_token"
    fi

    sha_list=$(echo "$existing_installers" | json_value "sha256")
    if [ -z "$sha_list" ]; then
        die "No sensor found for with OS Name: $cs_os_name"
    fi

    # Set the index accordingly (the json_value expects and index+1 value)
    INDEX=$((cs_falcon_sensor_version_dec + 1))

    sha=$(echo "$existing_installers" | json_value "sha256" "$INDEX" |
        sed 's/ *$//g' | sed 's/^ *//g')
    if [ -z "$sha" ]; then
        die "Unable to identify a sensor installer matching: $cs_os_name, version: $cs_os_version, index: N-$cs_falcon_sensor_version_dec"
    fi
    file_type=$(echo "$existing_installers" | json_value "file_type" "$INDEX" | sed 's/ *$//g' | sed 's/^ *//g')

    installer="${destination_dir}/falcon-sensor.${file_type}"

    curl_command "https://$(cs_cloud)/sensors/entities/download-installer/v1?id=$sha" -o "${installer}"

    handle_curl_error $?

    echo "$installer"
}

os_install_package() {
    local pkg="$1"

    rpm_install_package() {
        local pkg="$1"

        cs_falcon_gpg_import

        if type dnf >/dev/null 2>&1; then
            dnf install -q -y "$pkg" || rpm -ivh --nodeps "$pkg"
        elif type yum >/dev/null 2>&1; then
            yum install -q -y "$pkg" || rpm -ivh --nodeps "$pkg"
        elif type zypper >/dev/null 2>&1; then
            zypper --quiet install -y "$pkg" || rpm -ivh --nodeps "$pkg"
        else
            rpm -ivh --nodeps "$pkg"
        fi
    }
    # shellcheck disable=SC2221,SC2222
    case "${os_name}" in
        Amazon | CentOS | Oracle | RHEL | Rocky | AlmaLinux | SLES)
            rpm_install_package "$pkg"
            ;;
        Debian)
            DEBIAN_FRONTEND=noninteractive apt-get -qq install -y "$pkg" >/dev/null
            ;;
        Ubuntu)
            # If this is ubuntu 14, we need to use dpkg instead
            if [ "${cs_os_version}" -eq 14 ]; then
                DEBIAN_FRONTEND=noninteractive dpkg -i "$pkg" >/dev/null 2>&1 || true
                DEBIAN_FRONTEND=noninteractive apt-get -qq install -f -y >/dev/null
            else
                DEBIAN_FRONTEND=noninteractive apt-get -qq install -y "$pkg" >/dev/null
            fi
            ;;
        *)
            die "Unrecognized OS: ${os_name}"
            ;;
    esac
}

aws_ssm_parameter() {
    local param_name="$1"

    hmac_sha256() {
        key="$1"
        data="$2"
        echo -n "$data" | openssl dgst -sha256 -mac HMAC -macopt "$key" | sed 's/^.* //'
    }

    token=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
    api_endpoint="AmazonSSM.GetParameters"
    iam_role="$(curl -s -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/iam/security-credentials/)"
    aws_my_region="$(curl -s -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/placement/availability-zone | sed s/.$//)"
    _security_credentials="$(curl -s -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/iam/security-credentials/"$iam_role")"
    access_key_id="$(echo "$_security_credentials" | grep AccessKeyId | sed -e 's/  "AccessKeyId" : "//' -e 's/",$//')"
    access_key_secret="$(echo "$_security_credentials" | grep SecretAccessKey | sed -e 's/  "SecretAccessKey" : "//' -e 's/",$//')"
    security_token="$(echo "$_security_credentials" | grep Token | sed -e 's/  "Token" : "//' -e 's/",$//')"
    datetime=$(date -u +"%Y%m%dT%H%M%SZ")
    date=$(date -u +"%Y%m%d")
    request_data='{"Names":["'"${param_name}"'"],"WithDecryption":"true"}'
    request_data_dgst=$(echo -n "$request_data" | openssl dgst -sha256 | awk -F' ' '{print $2}')
    request_dgst=$(
        cat <<EOF | head -c -1 | openssl dgst -sha256 | awk -F' ' '{print $2}'
POST
/

content-type:application/x-amz-json-1.1
host:ssm.$aws_my_region.amazonaws.com
x-amz-date:$datetime
x-amz-security-token:$security_token
x-amz-target:$api_endpoint

content-type;host;x-amz-date;x-amz-security-token;x-amz-target
$request_data_dgst
EOF
    )
    dateKey=$(hmac_sha256 key:"AWS4$access_key_secret" "$date")
    dateRegionKey=$(hmac_sha256 "hexkey:$dateKey" "$aws_my_region")
    dateRegionServiceKey=$(hmac_sha256 "hexkey:$dateRegionKey" ssm)
    hex_key=$(hmac_sha256 "hexkey:$dateRegionServiceKey" "aws4_request")

    signature=$(
        cat <<EOF | head -c -1 | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$hex_key" | awk -F' ' '{print $2}'
AWS4-HMAC-SHA256
$datetime
$date/$aws_my_region/ssm/aws4_request
$request_dgst
EOF
    )

    response=$(
        curl -s "https://ssm.$aws_my_region.amazonaws.com/" \
            -x "$proxy" \
            -H "Authorization: AWS4-HMAC-SHA256 \
            Credential=$access_key_id/$date/$aws_my_region/ssm/aws4_request, \
            SignedHeaders=content-type;host;x-amz-date;x-amz-security-token;x-amz-target, \
            Signature=$signature" \
            -H "x-amz-security-token: $security_token" \
            -H "x-amz-target: $api_endpoint" \
            -H "content-type: application/x-amz-json-1.1" \
            -d "$request_data" \
            -H "x-amz-date: $datetime"
    )
    handle_curl_error $?
    if ! echo "$response" | grep -q '^.*"InvalidParameters":\[\].*$'; then
        die "Unexpected response from AWS SSM Parameter Store: $response"
    elif ! echo "$response" | grep -q '^.*'"${param_name}"'.*$'; then
        die "Unexpected response from AWS SSM Parameter Store: $response"
    fi
    echo "$response"
}

cs_falcon_gpg_import() {
    tempfile=$(mktemp)
    cat >"$tempfile" <<EOF
-----BEGIN PGP PUBLIC KEY BLOCK-----

mQINBGSd0wUBEADMlHjRUp7XEQf49xjlbyV/M6wv9rHvMg3NONypwSVSWndo7x1u
hnDcUeVFNv3AfMMM4c2+fNVdk8e5EN3rvU1+gsPwlj5rh0WHYldKqIfnjrZqnj2Y
ukDftSlpETgaIZFN0udg2HWGgZSViENldz8CDN4Q0oGF3s6GkhRpZA7ik7+EpbUf
vsvSfLKGUzREf8NGChmqjm7seoPiBVbU3uzALjDlHh1DHpHzk3obm+NEAi/t7+jj
6UWUox31Ta+lI4gzkfpiSxhduAe4HyIBaQ4pa0qCbfEt8ZII0RjMcppW7URlr3au
0nyQBphn/L6c3jdO3FFPKen31EucOYuVz4KSyAFr67UQl9nLlULuH3O78lkGBnNK
O33kkU1eGEavx/GfXwWCJd1tM8lCB0lLpvgvYN3q+/EvD/QDE/8cj117Z2U1lKY4
eT/d8yDJTM5ZerRZLEBH8nh+2Q4hOgyPvawN2x2YbIKVQs55mxLQd07OOB5RDov/
HG3kyeeRxIW+ObDqZq0w2d0zLhU1tANgEiH886L7jRhLik/ZpkWAqnACDLszcaOh
sRi1ACUMKTp5w5f/kdIVV1JMCxzkF2fzTPmP9nTxXEyHi2VUkKKQyu5b7sLT4EsL
RDffD3Mck95H+ALFdpeRgEmkgJ3xLi5HwPGWKWbEdOLR+pR1MrGVvdoeCwARAQAB
tElDcm93ZFN0cmlrZSwgSW5jLiAoZmFsY29uLXNlbnNvciBpbnN0YWxsZXIga2V5
KSA8c3VwcG9ydEBjcm93ZHN0cmlrZS5jb20+iQJSBBMBCAA8FiEEv2Mf1htUcfzg
UgvKXiAM4XmLyBgFAmSd0wUCGwMFCQHhM4AECwkIBwQVCgkIBRYCAwEAAh4BAheA
AAoJEF4gDOF5i8gYgGsQAJMafCytpjPWtjyVj5q9DA1hq5KjmcHrguPawNb/mlSF
i8M5JRbk5uhe1KSapPZJ5MxbWVXjzp+P3ebGzSlEvxNU7GvDpUPVEuuhzqjhLk/R
ZveT7dRFqUuHv8c2+8AztTdlAH4Q2BrozuGte10D1rlfCwE1pXucXA5Exd4/ec6m
xnpVN2bwu+CsyNCdYlSM8BO7dzmta+3QsKMxayGUtZYuEsUV1EXjnNdzt9eJVir9
Cpt31OR2M/i3l/Q/sW1x9k/9NTfx2iksC2I+nkR4T+Sb15Yq/8dJ8HkHZvOXAzot
7NhCECLpmIa7N6VmYvrCi8Fm5ovTsH2QzkvVaXrbSQppHQrS+bvvlzLfR14673HK
JDOSQyXLyMVqMpmftuBsdV68RSVf+vzF5e/WqaEB8qXQH/I8B3YDu9RNQrXLMyM/
mPk15KPO9kVjxujFFIlK9Ox1X2uqDY6yMDzgfbxopsIMd1Z6+Js1nqNbRy+5hGG0
8DHbRDlKrPX6TCEt68xVsOCsMi1+PbvgydLq6EB+mg/6cpK25upxHmcBF6HHKIm8
R2tyGD5elCPIi3U1IYGhXQFHGlvslKG0rhyBc1ya/pE8XQzv+KOh0OHGUG2COa4D
S/L9HPKBgdjltbptqo0c/vBdJFpRA405KR4ELcGPATq/6OODYMpjpZsrO2VreHNm
uQINBGSd0wUBEAC5pwLtqIrVKD+t9r3apWnysom9076HHFlsidND2o4S47XzfrZP
bdDuFH8QqWs58ZPLXfuzCIhq8GvvPWUoqTXcTxgtsauLAtyHBnexFxliXYbVh16T
SZTjrO/h2iTXgdPtqGVTA5SjZPZ8wTcOBNzctS9Q/kmwotySXSpXQDimzMBXSg/X
mX6g+ijz9wqFGBPdvU0rraWiVmLpMuJzpBW8GZsoXoEMdhLh+bd7Kq70lHxrC8IW
aYu57+MsIVe4Gdk7Zbs0XMwOWkGnA29Cixp8SvsdGhRj7FLC1wF0d2WGfhhsCHgm
EJbg7i6ch5lh8sdUM/ZbOvLYrAJ/Mao8z+1rh6cYA5vIJzaX3IO/cazivylhlcnk
u2Fzobks9KVTZXTHQ1J1pqtusqDtVTTs7n7svYiSWV0rT7CM/oCJCNfHTUDk5mwu
/NJSwNF/I598i3j1rZYNzaZ02SvpXOTakk4rZ+hRdX+nvhHG+0df+O7deu35LFoN
MVKYcTRkUBAGnp6mtwDd+DrRDMNwlsOJyv5GXWadK+RMSRb5KRxIDRqXt9D06AdQ
9DKFxta8IZekdzN6RlrkGCrVXF/LHDgLKVCOKFBgj2HP+XsPm2t3c8H+KbdSGJHi
9lJqjvF7+BpQLzFFmT0VIpbrHKGw/BqMD997ZzzIyHKXhSRBU0vq/v1EUQARAQAB
iQI8BBgBCAAmFiEEv2Mf1htUcfzgUgvKXiAM4XmLyBgFAmSd0wUCGwwFCQHhM4AA
CgkQXiAM4XmLyBhPkg//V+wL2TGlzFCV5ZTbPPiGNVFpuiAJVr+qyu80bSmo8xx+
91R5/z74gIYHxBdBS6gqmDWOJbJi56DMmhK6qq2cSPJbVoO9KrA03oyaJ+EMK9gX
vnxM2/G1CjqC6yFB8ZJgit77LEsC/BkJ6aQf3JvA4spBrbA7nt6RHehXQaTd93o0
IYBfD66qzzHgfnHXtDyyI82Bwft+Q8Q+pXOOX198V+7fyd/1eU8o/qx4jMTFw9Yw
1yDDDZoVNCxWSqOKvQZF0DNu2m8nNqx0vyFYwuV7vtm/Zb3briOB6kqcq3y5Rbiq
EoSemMkYL7WWYqwQmOrFKbHk6t0QwwQ9H+632hriAp1iN2vcTwhrvSt3tZcOfEK5
QD+oDtBWM3xwVrPDVGQfTbNHhg8D/mZUuxgLeVhaM7z2Gz7Dhb5iu9eD0w1xfaZ4
HeJJM45ZkZwhBOi9HFA6eM4p9Gd2uh11wpPcAigaFifylq8+evl6xseXmk8mQHpa
yjXMIJXGMLUecZuquNwkcQzb698HxOqwoLWUnYfPK4Une8Werb+04JVvEJI4Herf
azCTeDb8lfUKaNuc2eMvtBE1T+Vi/CA4keDP83vKUcK0Mwvstfue47kqFbuOuF8L
jEtro8ozeQjCFdwTjXwBh8PYJIPWgx/bdsQTavw9hhvesSBZ59U82tjnMGZzZTA=
=du8f
-----END PGP PUBLIC KEY BLOCK-----
EOF
    rpm --import "$tempfile"
    rm "$tempfile"
}

set -e

json_value() {
    KEY=$1
    num=$2
    awk -F"[,:}]" '{for(i=1;i<=NF;i++){if($i~/'"$KEY"'\042/){print $(i+1)}}}' | tr -d '"' | sed -n "${num}p"
}

die() {
    echo "Fatal error: $*" >&2
    exit 1
}

cs_cloud() {
    case "${cs_falcon_cloud}" in
        us-1) echo "api.crowdstrike.com" ;;
        us-2) echo "api.us-2.crowdstrike.com" ;;
        eu-1) echo "api.eu-1.crowdstrike.com" ;;
        us-gov-1) echo "api.laggar.gcw.crowdstrike.com" ;;
        *) die "Unrecognized Falcon Cloud: ${cs_falcon_cloud}" ;;
    esac
}

# Check if curl is greater or equal to 7.55
old_curl=$(
    if ! command -v curl >/dev/null 2>&1; then
        die "The 'curl' command is missing. Please install it before continuing. Aborting..."
    fi

    version=$(curl --version | head -n 1 | awk '{ print $2 }')
    minimum="7.55"

    # Check if the version is less than the minimum
    if printf "%s\n" "$version" "$minimum" | sort -V -C; then
        echo 0
    else
        echo 1
    fi
)

# Old curl print warning message
if [ "$old_curl" -eq 0 ]; then
    if [ "${ALLOW_LEGACY_CURL}" != "true" ]; then
        echo """
WARNING: Your version of curl does not support the ability to pass headers via stdin.
For security considerations, we strongly recommend upgrading to curl 7.55.0 or newer.

To bypass this warning, set the environment variable ALLOW_LEGACY_CURL=true
"""
        exit 1
    fi
fi

# Handle error codes returned by curl
handle_curl_error() {
    local err_msg

    # Failed to download the file to destination
    if [ "$1" -eq 23 ]; then
        err_msg="Failed writing received data to disk/destination (exit code 23). Please check the destination path and permissions."
        die "$err_msg"
    fi

    # Proxy related errors
    if [ "$1" = "28" ]; then
        err_msg="Operation timed out (exit code 28)."
        if [ -n "$proxy" ]; then
            err_msg="$err_msg A proxy was used to communicate ($proxy). Please check your proxy settings."
        fi
        die "$err_msg"
    fi

    if [ "$1" = "5" ]; then
        err_msg="Couldn't resolve proxy (exit code 5). The address ($proxy) of the given proxy host could not be resolved. Please check your proxy settings."
        die "$err_msg"
    fi

    if [ "$1" = "7" ]; then
        err_msg="Failed to connect to host (exit code 7). Host found, but unable to open connection with host."
        if [ -n "$proxy" ]; then
            err_msg="$err_msg A proxy was used to communicate ($proxy). Please check your proxy settings."
        fi
        die "$err_msg"
    fi
}

curl_command() {
    # Dash does not support arrays, so we have to pass the args as separate arguments
    set -- "$@"

    if [ "$old_curl" -eq 0 ]; then
        curl -s -x "$proxy" -L -H "Authorization: Bearer ${cs_falcon_oauth_token}" "$@"
    else
        echo "Authorization: Bearer ${cs_falcon_oauth_token}" | curl -s -x "$proxy" -L -H @- "$@"
    fi
}

check_aws_instance() {
    local aws_instance

    # Check if running on EC2 hypervisor
    if [ -f /sys/hypervisor/uuid ] && grep -qi ec2 /sys/hypervisor/uuid; then
        aws_instance=true
    # Check if DMI board asset tag matches EC2 instance pattern
    elif [ -f /sys/devices/virtual/dmi/id/board_asset_tag ] && grep -q '^i-[a-z0-9]*$' /sys/devices/virtual/dmi/id/board_asset_tag; then
        aws_instance=true
    # Check if EC2 instance identity document is accessible
    else
        curl_output="$(curl -s --connect-timeout 5 http://169.254.169.254/latest/dynamic/instance-identity/)"
        if [ -n "$curl_output" ] && ! echo "$curl_output" | grep --silent -i 'not.*found'; then
            aws_instance=true
        fi
    fi

    echo "$aws_instance"
}

get_falcon_credentials() {
    if [ -z "$FALCON_ACCESS_TOKEN" ]; then
        aws_instance=$(check_aws_instance)
        cs_falcon_client_id=$(
            if [ -n "$FALCON_CLIENT_ID" ]; then
                echo "$FALCON_CLIENT_ID"
            elif [ -n "$aws_instance" ]; then
                aws_ssm_parameter "FALCON_CLIENT_ID" | json_value Value 1
            else
                die "Missing FALCON_CLIENT_ID environment variable. Please provide your OAuth2 API Client ID for authentication with CrowdStrike Falcon platform. Establishing and retrieving OAuth2 API credentials can be performed at https://falcon.crowdstrike.com/support/api-clients-and-keys."
            fi
        )

        cs_falcon_client_secret=$(
            if [ -n "$FALCON_CLIENT_SECRET" ]; then
                echo "$FALCON_CLIENT_SECRET"
            elif [ -n "$aws_instance" ]; then
                aws_ssm_parameter "FALCON_CLIENT_SECRET" | json_value Value 1
            else
                die "Missing FALCON_CLIENT_SECRET environment variable. Please provide your OAuth2 API Client Secret for authentication with CrowdStrike Falcon platform. Establishing and retrieving OAuth2 API credentials can be performed at https://falcon.crowdstrike.com/support/api-clients-and-keys."
            fi
        )
    else
        if [ -z "$FALCON_CLOUD" ]; then
            die "If setting the FALCON_ACCESS_TOKEN manually, you must also specify the FALCON_CLOUD"
        fi
    fi
}

get_oauth_token() {
    # Get credentials first
    get_falcon_credentials

    cs_falcon_oauth_token=$(
        if [ -n "$FALCON_ACCESS_TOKEN" ]; then
            token=$FALCON_ACCESS_TOKEN
        else
            token_result=$(echo "client_id=$cs_falcon_client_id&client_secret=$cs_falcon_client_secret" |
                curl -X POST -s -x "$proxy" -L "https://$(cs_cloud)/oauth2/token" \
                    -H 'Content-Type: application/x-www-form-urlencoded; charset=utf-8' \
                    -H 'User-Agent: crowdstrike-falcon-scripts/1.4.1' \
                    --dump-header "${response_headers}" \
                    --data @-)

            handle_curl_error $?

            token=$(echo "$token_result" | json_value "access_token" | sed 's/ *$//g' | sed 's/^ *//g')
            if [ -z "$token" ]; then
                die "Unable to obtain CrowdStrike Falcon OAuth Token. Double check your credentials and/or ensure you set the correct cloud region."
            fi
        fi
        echo "$token"
    )

    if [ -z "$FALCON_ACCESS_TOKEN" ]; then
        region_hint=$(grep -i ^x-cs-region: "$response_headers" | head -n 1 | tr '[:upper:]' '[:lower:]' | tr -d '\r' | sed 's/^x-cs-region: //g')

        if [ -z "${FALCON_CLOUD}" ]; then
            if [ -z "${region_hint}" ]; then
                die "Unable to obtain region hint from CrowdStrike Falcon OAuth API, Please provide FALCON_CLOUD environment variable as an override."
            fi
            cs_falcon_cloud="${region_hint}"
        else
            if [ "x${FALCON_CLOUD}" != "x${region_hint}" ]; then
                echo "WARNING: FALCON_CLOUD='${FALCON_CLOUD}' environment variable specified while credentials only exists in '${region_hint}'" >&2
            fi
        fi
    fi

    rm "${response_headers}"
}

get_falcon_cid() {
    if [ -n "$FALCON_CID" ]; then
        echo "$FALCON_CID"
    else
        cs_target_cid=$(curl_command "https://$(cs_cloud)/sensors/queries/installers/ccid/v1")

        handle_curl_error $?

        if [ -z "$cs_target_cid" ]; then
            die "Unable to obtain CrowdStrike Falcon CID. Response was $cs_target_cid"
        fi
        echo "$cs_target_cid" | tr -d '\n" ' | awk -F'[][]' '{print $2}'
    fi
}

# shellcheck disable=SC2034
cs_uninstall=$(
    if [ "$FALCON_UNINSTALL" ]; then
        echo -n 'Removing Falcon Sensor  ... '
        cs_sensor_remove
        echo '[ Ok ]'
        echo 'Falcon Sensor removed successfully.'
        exit 2
    fi
)

os_name=$(
    # returns either: Amazon, Ubuntu, CentOS, RHEL, or SLES
    # lsb_release is not always present
    name=$(cat /etc/*release | grep ^NAME= | awk -F'=' '{ print $2 }' | sed "s/\"//g;s/Red Hat.*/RHEL/g;s/ Linux$//g;s/ GNU\/Linux$//g;s/Oracle.*/Oracle/g;s/Amazon.*/Amazon/g")
    if [ -z "$name" ]; then
        if lsb_release -s -i | grep -q ^RedHat; then
            name="RHEL"
        elif [ -f /usr/bin/lsb_release ]; then
            name=$(/usr/bin/lsb_release -s -i)
        fi
    fi
    if [ -z "$name" ]; then
        die "Cannot recognise operating system"
    fi

    echo "$name"
)

os_version=$(
    version=$(cat /etc/*release | grep VERSION_ID= | awk '{ print $1 }' | awk -F'=' '{ print $2 }' | sed "s/\"//g")
    if [ -z "$version" ]; then
        if type rpm >/dev/null 2>&1; then
            # older systems may have *release files of different form
            version=$(rpm -qf /etc/redhat-release --queryformat '%{VERSION}' | sed 's/\([[:digit:]]\+\).*/\1/g')
        elif [ -f /etc/debian_version ]; then
            version=$(cat /etc/debian_version)
        elif [ -f /usr/bin/lsb_release ]; then
            version=$(/usr/bin/lsb_release -r | /usr/bin/cut -f 2-)
        fi
    fi
    if [ -z "$version" ]; then
        cat /etc/*release >&2
        die "Could not determine distribution version"
    fi
    echo "$version"
)

cs_os_name=$(
    # returns OS name as recognised by CrowdStrike Falcon API
    # shellcheck disable=SC2221,SC2222
    case "${os_name}" in
        Amazon)
            echo "Amazon Linux"
            ;;
        CentOS | Oracle | RHEL | Rocky | AlmaLinux)
            echo "*RHEL*"
            ;;
        Debian)
            echo "Debian"
            ;;
        SLES)
            echo "SLES"
            ;;
        Ubuntu)
            echo "Ubuntu"
            ;;
        *)
            die "Unrecognized OS: ${os_name}"
            ;;
    esac
)

cs_os_arch=$(
    uname -m
)

cs_os_arch_filter=$(
    case "${cs_os_arch}" in
        x86_64)
            echo "+os_version:!~\"arm64\"+os_version:!~\"zLinux\""
            ;;
        aarch64)
            echo "+os_version:~\"arm64\""
            ;;
        s390x)
            echo "+os_version:~\"zLinux\""
            ;;
        *)
            die "Unrecognized OS architecture: ${cs_os_arch}"
            ;;
    esac
)

cs_os_version=$(
    version=$(echo "$os_version" | awk -F'.' '{print $1}')
    # Check if we are using Amazon Linux 1
    if [ "${os_name}" = "Amazon" ]; then
        if [ "$version" != "2" ] && [ "$version" -le 2018 ]; then
            version="1"
        fi
    fi
    echo "$version"
)

cs_falcon_token=$(
    if [ -n "$FALCON_PROVISIONING_TOKEN" ]; then
        echo "$FALCON_PROVISIONING_TOKEN"
    fi
)

cs_falcon_cloud=$(
    if [ -n "$FALCON_CLOUD" ]; then
        echo "$FALCON_CLOUD"
    else
        # Auto-discovery is using us-1 initially
        echo "us-1"
    fi
)

cs_sensor_policy_name=$(
    if [ -n "$FALCON_SENSOR_UPDATE_POLICY_NAME" ]; then
        echo "$FALCON_SENSOR_UPDATE_POLICY_NAME"
    else
        echo ""
    fi
)

cs_falcon_sensor_version_dec=$(
    re='^[0-9]\+$'
    if [ -n "$FALCON_SENSOR_VERSION_DECREMENT" ]; then
        if ! expr "$FALCON_SENSOR_VERSION_DECREMENT" : "$re" >/dev/null 2>&1; then
            die "The FALCON_SENSOR_VERSION_DECREMENT must be an integer greater than or equal to 0 or less than 5. FALCON_SENSOR_VERSION_DECREMENT: \"$FALCON_SENSOR_VERSION_DECREMENT\""
        elif [ "$FALCON_SENSOR_VERSION_DECREMENT" -lt 0 ] || [ "$FALCON_SENSOR_VERSION_DECREMENT" -gt 5 ]; then
            die "The FALCON_SENSOR_VERSION_DECREMENT must be an integer greater than or equal to 0 or less than 5. FALCON_SENSOR_VERSION_DECREMENT: \"$FALCON_SENSOR_VERSION_DECREMENT\""
        else
            echo "$FALCON_SENSOR_VERSION_DECREMENT"
        fi
    else
        echo "0"
    fi
)

response_headers=$(mktemp)

# shellcheck disable=SC2001
proxy=$(
    proxy=""
    if [ -n "$FALCON_APH" ]; then
        proxy="$(echo "$FALCON_APH" | sed "s|http.*://||")"

        if [ -n "$FALCON_APP" ]; then
            proxy="$proxy:$FALCON_APP"
        fi
    fi

    if [ -n "$proxy" ]; then
        # Remove redundant quotes
        proxy="$(echo "$proxy" | sed "s/[\'\"]//g")"
        proxy="http://$proxy"
    fi
    echo "$proxy"
)

if [ -n "$FALCON_APD" ]; then
    cs_falcon_apd=$(
        case "${FALCON_APD}" in
            true)
                echo "true"
                ;;
            false)
                echo "false"
                ;;
            *)
                die "Unrecognized APD: ${FALCON_APD} value must be one of : [true|false]"
                ;;
        esac
    )
fi

if [ -n "$FALCON_BILLING" ]; then
    cs_falcon_billing=$(
        case "${FALCON_BILLING}" in
            default)
                echo "default"
                ;;
            metered)
                echo "metered"
                ;;
            *)
                die "Unrecognized BILLING: ${FALCON_BILLING} value must be one of : [default|metered]"
                ;;
        esac
    )
fi

if [ -n "$FALCON_BACKEND" ]; then
    cs_falcon_backend=$(
        case "${FALCON_BACKEND}" in
            auto)
                echo "auto"
                ;;
            bpf)
                echo "bpf"
                ;;
            kernel)
                echo "kernel"
                ;;
            *)
                die "Unrecognized BACKEND: ${FALCON_BACKEND} value must be one of : [auto|bpf|kernel]"
                ;;
        esac
    )
fi

if [ -n "$FALCON_TRACE" ]; then
    cs_falcon_trace=$(
        case "${FALCON_TRACE}" in
            none)
                echo "none"
                ;;
            err)
                echo "err"
                ;;
            warn)
                echo "warn"
                ;;
            info)
                echo "info"
                ;;
            debug)
                echo "debug"
                ;;
            *)
                die "Unrecognized TRACE: ${FALCON_TRACE} value must be one of : [none|err|warn|info|debug]"
                ;;
        esac
    )
fi

main "$@"
