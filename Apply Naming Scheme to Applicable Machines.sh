#!/bin/bash

#Jamf Username
username="(Username of your API account)"
#Jamf Password
password="(Password to your API account)"
#Your JAMF URL
url="(URL of your jamf instance)"

#Methods
getBearerToken() {
    response=$(curl -s -u "$username":"$password" "$url"/api/v1/auth/token -X POST)
    bearerToken=$(echo "$response" | plutil -extract token raw -)
    tokenExpiration=$(echo "$response" | plutil -extract expires raw - | awk -F . '{print $1}')
    tokenExpirationEpoch=$(date -j -f "%Y-%m-%dT%T" "$tokenExpiration" +"%s")
}

checkTokenExpiration() {
    nowEpochUTC=$(date -j -f "%Y-%m-%dT%T" "$(date -u +"%Y-%m-%dT%T")" +"%s")
    if [[ tokenExpirationEpoch -gt nowEpochUTC ]]
    then
        echo "Token valid until the following epoch time: " "$tokenExpirationEpoch"
    else
        echo "No valid token available, getting new token"
        getBearerToken
    fi
}

invalidateToken() {
    responseCode=$(curl -w "%{http_code}" -H "Authorization: Bearer ${bearerToken}" "$url"/api/v1/auth/invalidate-token -X POST -s -o /dev/null)
    if [[ ${responseCode} == 204 ]]
    then
        echo "Token successfully invalidated"
        bearerToken=""
        tokenExpirationEpoch="0"
    elif [[ ${responseCode} == 401 ]]
    then
        echo "Token already invalid"
    else
        echo "An unknown error occurred invalidating the token"
    fi
}

#Logs in
getBearerToken


#Setup all the variables, pulling info from the jamf API

#Gets the computer's MAC address, used to pull data from the Jamf Classic API
MACADDRESS=$(networksetup -getmacaddress en0 | awk '{ print $3 }')

#Gets the asset tag from the asset info field in the jamf computer record
ASSET_TAG_INFO=$(curl -k $url:443/JSSResource/computers/macaddress/$MACADDRESS --header "Authorization: Bearer ${bearerToken}" | xmllint --xpath '/computer/general/asset_tag/text()' -)

#Serial number of the computer
SERIAL_NUMBER=$(system_profiler SPHardwareDataType | awk '/Serial/ {print $4}')

#If you want a prefix before the computer name, enter it here
PREFIX=""

#Pulls from the Barcode 1 field in jamf. I fill this using inventory preload, but it can also be changed manually in the computer record. 
BARCODE=$(curl -k $url:443/JSSResource/computers/macaddress/$MACADDRESS --header "Authorization: Bearer ${bearerToken}" | xmllint --xpath '/computer/general/barcode_1/text()' -)

#I use the UPPER variable as a temp variable for formatting the suffix based on the barcode. To match our AD naming scheme, I truncate the number of characters in the barcode field before using it as the suffix, but this is specific to our environment and not necessary.
UPPER=${BARCODE:0:7}

#This sets the SUFFIX to whatever is in the barcode field, all lowercase, and only alphanumeric characters. As I'm typing this note I'm realizing a flaw in this, in that if there are non-alphanumeric characters in the barcode field it truncates to 7 characters before removing them, so some names might be shorter. I'll worry about this later. You can set the SUFFIX to whatever you want though. 
SUFFIX=$(echo $UPPER | tr '[:upper:]' '[:lower:]' | tr -dc '[:alnum:]')

#Here's all the math to actually set the name of the computer based on the above variables.

#If the computer record has values in both the asset tag and barcode fields in Jamf, the name format of "1234usernam" is applied, where 1234 is the asset tag and "Username" is the user's name (Manually entered into the barcode field)
if [ -n "$ASSET_TAG_INFO" ] && [ -n "$SUFFIX" ]; then
    echo "Processing new name for this client..."
    echo "Changing name..."
    scutil --set HostName $PREFIX"$ASSET_TAG_INFO"$SUFFIX
    scutil --set ComputerName $PREFIX"$ASSET_TAG_INFO"$SUFFIX
    echo "Name change complete. ($PREFIX"$ASSET_TAG_INFO"$SUFFIX)"

#If the computer record in jamf has the asset tag filled out but nothing in the barcode field, it's assigned the arbitrary suffix of "mbp" for MacBook Pro (Even if it's an iMac, I just haven't bothered to fix this because it doesn't really matter), then the name is set as "1234mbp" where "1234" is the asset tag.
elif [ -n "$ASSET_TAG_INFO" ] && [ ! -n "$SUFFIX" ]; then
    SUFFIX="mbp"
    echo "Processing new name for this client..."
    echo "Changing name..."
    scutil --set HostName $PREFIX"$ASSET_TAG_INFO"$SUFFIX
    scutil --set ComputerName $PREFIX"$ASSET_TAG_INFO"$SUFFIX
    echo "Name change complete. ($PREFIX"$ASSET_TAG_INFO"$SUFFIX)"

#If the computer record doesn't have an asset tag, the computer name is just set to the serial number of the computer with the suffix "mbp" for MacBook Pro, again even if it's an iMac. 
else
    SUFFIX="mbp"
    echo "Asset Tag and User information was unavailable. Using Serial Number instead."
    echo "Changing Name..."
    scutil --set HostName $PREFIX$SERIAL_NUMBER$SUFFIX
    echo "Name Change Complete ($PREFIX$SERIAL_NUMBER$SUFFIX)"

fi

#Always expire your tokens when you're done
invalidateToken
