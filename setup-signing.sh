#!/bin/zsh
# 로컬 전용 코드 서명 인증서를 로그인 키체인에 한 번 만들어 둡니다.
# ad-hoc 서명은 빌드할 때마다 서명이 바뀌어 macOS 권한(화면 기록·손쉬운 사용)이 매번 풀립니다.
# 같은 인증서로 서명하면 빌드가 바뀌어도 macOS가 같은 앱으로 알아봐 권한이 유지됩니다.
# 인증서는 이 Mac에서만 쓰이며 시스템 신뢰 설정은 바꾸지 않습니다. 삭제: 키체인 접근에서 아래 이름 검색.
set -euo pipefail

NAME="AI Usage Bar Local Signing"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
    echo "==> 이미 있음: $NAME"
    exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PASS=$(uuidgen)

cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$WORK/cert.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/id.p12" -passout "pass:$PASS" 2>/dev/null
security import "$WORK/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P "$PASS" -T /usr/bin/codesign >/dev/null

echo "==> 만들었음: $NAME"
