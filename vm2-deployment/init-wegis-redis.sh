#!/bin/bash
# Wegis Redis Initialization Script
# Run this on VM3 to initialize Redis with domain lists

set -e

VM3_IP="10.0.2.134"
REDIS_DB=4

echo "Initializing Wegis Redis data on VM3 (${VM3_IP})..."

# Check if redis-cli is available
if ! command -v redis-cli &> /dev/null; then
    echo "Installing redis-cli..."
    sudo apt-get update && sudo apt-get install -y redis-tools
fi

echo "Adding whitelist domains to Redis DB ${REDIS_DB}..."
redis-cli -h ${VM3_IP} -n ${REDIS_DB} SADD "wegis:whitelist:domains" \
    "google.com" "amazon.com" "microsoft.com" "apple.com" \
    "facebook.com" "instagram.com" "twitter.com" "linkedin.com" \
    "github.com" "stackoverflow.com" "wikipedia.org" "youtube.com" \
    "netflix.com" "cnn.com" "bbc.com" "nytimes.com" "reddit.com" \
    "openai.com" "naver.com" "daum.net" "kakao.com" "samsung.com" "lg.com"

echo "Adding whitelist patterns..."
redis-cli -h ${VM3_IP} -n ${REDIS_DB} SADD "wegis:whitelist:patterns" \
    "*.google.com" "*.amazon.com" "*.microsoft.com" "*.apple.com" \
    "*.github.com" "*.stackoverflow.com" "*.wikipedia.org" \
    "*.youtube.com" "*.naver.com" "*.kakao.com"

echo "Initializing empty blacklist keys..."
redis-cli -h ${VM3_IP} -n ${REDIS_DB} SADD "wegis:blacklist:domains" "__placeholder__"
redis-cli -h ${VM3_IP} -n ${REDIS_DB} SREM "wegis:blacklist:domains" "__placeholder__"
redis-cli -h ${VM3_IP} -n ${REDIS_DB} SADD "wegis:blacklist:patterns" "__placeholder__"
redis-cli -h ${VM3_IP} -n ${REDIS_DB} SREM "wegis:blacklist:patterns" "__placeholder__"

echo ""
echo "✅ Wegis Redis initialization completed!"
echo "Whitelist domains count: $(redis-cli -h ${VM3_IP} -n ${REDIS_DB} SCARD wegis:whitelist:domains)"
echo "Whitelist patterns count: $(redis-cli -h ${VM3_IP} -n ${REDIS_DB} SCARD wegis:whitelist:patterns)"
echo "Blacklist keys initialized (empty)"

