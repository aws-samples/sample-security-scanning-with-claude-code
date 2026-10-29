# shellcheck shell=bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# Defending-code harness: scan-harness.sh from the kit bucket, the harness clone for the claude user, and the
# claude-scanner user that headless scans run as (see scan-harness.sh): no sudo, no access to other users'
# files, no AWS credentials but a short-term Bedrock key, and firewall rules that allow only the VPC's endpoints
aws s3 cp --region "$REGION" "s3://$ARTIFACT_BUCKET/${ARTIFACT_PREFIX}scripts/scan-harness.sh" /usr/local/bin/scan-harness.sh
chmod 755 /usr/local/bin/scan-harness.sh
as_user 'scan-harness.sh setup'

# Mints the Bedrock API keys for headless scans from the user's sign-in
[[ -x $LIB_DIR/bedrock-token/bin/python3 ]] || python3 -m venv "$LIB_DIR/bedrock-token"
"$LIB_DIR/bedrock-token/bin/pip" install -q aws-bedrock-token-generator==1.1.0

S=claude-scanner
id "$S" >/dev/null 2>&1 || useradd -m -s /bin/bash "$S"
chmod 700 "/home/$S" "$H"
install -d -o "$S" -g "$S" -m 700 /var/lib/claude-scan/scans
# Its Claude Code install needs the internet, so a rerun lifts the firewall below until it's loaded again
dnf install -y nftables
nft delete table inet claude_scanner 2>/dev/null || true
sudo -iu "$S" bash -o pipefail -lc 'curl -fsSL https://claude.ai/install.sh | bash -s stable'

# Firewall for claude-scanner: loopback (the telemetry collector), DNS, and HTTPS to the VPC (its interface
# endpoints); everything else is dropped, including the internet and instance metadata
token=$(curl -fsS -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token)
md() { curl -fsS -H "X-aws-ec2-metadata-token: $token" "http://169.254.169.254/latest/meta-data/$1"; }
mac=$(md mac)
md "network/interfaces/macs/$mac/vpc-ipv4-cidr-blocks" > /etc/claude-scan/scanner-vpc-cidrs
resolver=$(python3 -I -c 'import ipaddress, sys; print(ipaddress.ip_network(sys.argv[1]).network_address + 2)' \
  "$(md "network/interfaces/macs/$mac/vpc-ipv4-cidr-block")")
cat > /etc/claude-scan/scanner.nft <<EOF
table inet claude_scanner
delete table inet claude_scanner
table inet claude_scanner {
  chain out {
    type filter hook output priority 0; policy accept;
    meta skuid "$S" oif "lo" accept
    meta skuid "$S" ip daddr { $resolver, 169.254.169.253 } udp dport 53 accept
    meta skuid "$S" ip daddr { $resolver, 169.254.169.253 } tcp dport 53 accept
    meta skuid "$S" ip daddr { $(paste -sd, /etc/claude-scan/scanner-vpc-cidrs) } tcp dport 443 accept
    meta skuid "$S" counter drop
  }
}
EOF
cat > /etc/systemd/system/claude-scan-scanner-firewall.service <<'EOF'
[Unit]
Description=Firewall rules for claude-scanner (headless scans)

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/claude-scan/scanner.nft

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable claude-scan-scanner-firewall
systemctl restart claude-scan-scanner-firewall
