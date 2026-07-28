#!/bin/bash
# 创建固定的自签名代码签名证书「TidyApp Dev」(§11.2)。
# 目的:TCC 授权绑定签名身份;固定证书使授权跨 rebuild 保留。
# 过程中 macOS 可能弹 1-2 次密码确认框(导入钥匙串 / 信任设置),属正常。
set -euo pipefail

IDENTITY="TidyApp Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if security find-identity -p codesigning -v 2>/dev/null | grep -q "$IDENTITY"; then
    echo "✓ 证书「$IDENTITY」已存在,无需重复创建"
    exit 0
fi

echo "==> 生成自签名代码签名证书(有效期 10 年)"
cat > "$TMP/ext.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = TidyApp Dev
[v3]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
basicConstraints = critical,CA:false
EOF
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/ext.cnf" 2>/dev/null

echo "==> 导入登录钥匙串(允许 codesign 访问)"
# PKCS#8 → 传统 RSA PEM(security import 只认后者;OpenSSL 3 需 -traditional)
openssl rsa -traditional -in "$TMP/key.pem" -out "$TMP/key_rsa.pem" 2>/dev/null
security import "$TMP/key_rsa.pem" -k "$KEYCHAIN" -t priv -f openssl \
    -T /usr/bin/codesign -T /usr/bin/security
security import "$TMP/cert.pem" -k "$KEYCHAIN" -t cert -f openssl

echo "==> 设置为代码签名可信(可能弹出密码确认)"
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" || {
    echo "⚠️  信任设置未完成。可手动操作:钥匙串访问 → 登录 → 证书「$IDENTITY」→ 信任 → 代码签名:始终信任"
}

if security find-identity -p codesigning -v | grep -q "$IDENTITY"; then
    echo "✓ 完成。之后 ./build.sh 会自动用「$IDENTITY」签名"
else
    echo "⚠️  证书尚未生效(通常是信任设置未完成),build.sh 会暂时回落到 ad-hoc 签名"
fi
