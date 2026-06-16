#!/bin/bash
set -e

DOMAIN="t.yinmutree.cn"
ACME="/root/.acme.sh/acme.sh"
SSL_DIR="/www/server/nginx/conf/ssl/${DOMAIN}"
VHOST_DIR="/www/server/nginx/conf/vhost"

echo "========================================="
echo " 引木访客追踪 HTTPS 一键配置脚本"
echo " 域名: ${DOMAIN}"
echo "========================================="

# Step 1: Find webroot
echo ""
echo "[1/6] 查找网站根目录..."
WEBROOT=""
for dir in /www/wwwroot/${DOMAIN} /www/wwwroot/t.yinmutree.cn; do
  if [ -d "$dir" ]; then
    WEBROOT="$dir"
    break
  fi
done
if [ -z "$WEBROOT" ]; then
  # Try to find from nginx config
  WEBROOT=$(grep -r "root " ${VHOST_DIR}/${DOMAIN}.conf 2>/dev/null | head -1 | grep -oP '(?<=root\s).+?;' | tr -d ';' | head -1 | tr -d ' ')
fi
if [ -z "$WEBROOT" ]; then
  WEBROOT="/www/wwwroot/${DOMAIN}"
  mkdir -p "$WEBROOT"
  echo "  创建默认根目录: $WEBROOT"
else
  echo "  找到根目录: $WEBROOT"
fi

# Step 2: Issue SSL certificate
echo ""
echo "[2/6] 申请SSL证书 (Let's Encrypt)..."
echo "  使用 webroot 模式，Nginx 无需重启..."

# Try webroot mode first
if ${ACME} --issue -d ${DOMAIN} --webroot "$WEBROOT" --force 2>&1; then
  echo "  ✅ 证书签发成功！"
else
  echo "  webroot模式失败，尝试 nginx 模式..."
  if ${ACME} --issue -d ${DOMAIN} --nginx --force 2>&1; then
    echo "  ✅ 证书签发成功！"
  else
    echo ""
    echo "  ❌ 自动签发失败。尝试 standalone 模式（需要临时停Nginx）..."
    echo "  正在停止 Nginx..."
    /etc/init.d/nginx stop 2>/dev/null || systemctl stop nginx 2>/dev/null || true
    sleep 1
    if ${ACME} --issue -d ${DOMAIN} --standalone --force 2>&1; then
      echo "  ✅ 证书签发成功！"
    else
      echo "  ❌ 所有模式都失败了，请截图报错信息"
      /etc/init.d/nginx start 2>/dev/null || systemctl start nginx 2>/dev/null || true
      exit 1
    fi
    echo "  重启 Nginx..."
    /etc/init.d/nginx start 2>/dev/null || systemctl start nginx 2>/dev/null || true
  fi
fi

# Step 3: Install certificate
echo ""
echo "[3/6] 安装证书文件..."
mkdir -p ${SSL_DIR}
${ACME} --install-cert -d ${DOMAIN} \
  --cert-file ${SSL_DIR}/${DOMAIN}.crt \
  --key-file ${SSL_DIR}/${DOMAIN}.key \
  --fullchain-file ${SSL_DIR}/${DOMAIN}.fullchain.cer \
  --reloadcmd "nginx -s reload"
echo "  ✅ 证书已安装"

# Step 4: Write Nginx SSL + reverse proxy config
echo ""
echo "[4/6] 配置 Nginx SSL + 反向代理..."
python3 -c "
config = '''server {
    listen 80;
    server_name t.yinmutree.cn;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name t.yinmutree.cn;

    ssl_certificate /www/server/nginx/conf/ssl/t.yinmutree.cn/t.yinmutree.cn.fullchain.cer;
    ssl_certificate_key /www/server/nginx/conf/ssl/t.yinmutree.cn/t.yinmutree.cn.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    location / {
        proxy_pass http://127.0.0.1:8901;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
'''
with open('/www/server/nginx/conf/vhost/t.yinmutree.cn.conf', 'w') as f:
    f.write(config)
print('  ✅ Nginx配置已写入')
"

# Step 5: Test and reload Nginx
echo ""
echo "[5/6] 测试并重载 Nginx..."
if nginx -t 2>&1; then
  nginx -s reload
  echo "  ✅ Nginx 重载成功"
else
  echo "  ❌ Nginx配置有误，请检查上方错误信息"
  exit 1
fi

# Step 6: Verify
echo ""
echo "[6/6] 验证 HTTPS..."
sleep 2
if curl -sk https://${DOMAIN}/api/stats 2>/dev/null | grep -q "total_visitors"; then
  echo "  ✅ HTTPS 访问成功！"
else
  echo "  ⚠️  HTTPS验证未通过，可能需要检查防火墙443端口是否放行"
fi

echo ""
echo "========================================="
echo " 🎉 配置完成！"
echo " HTTPS地址: https://${DOMAIN}"
echo " 后台页面: https://${DOMAIN}/"
echo " API统计: https://${DOMAIN}/api/stats"
echo "========================================="
