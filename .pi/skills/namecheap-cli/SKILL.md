---
name: namecheap-cli
description: Use when managing Namecheap domains, DNS records, nameservers, email forwarding, privacy, or CLI configuration with `namecheap-cli`.
---

# Namecheap CLI

Use this skill when the user asks to inspect, configure, or change Namecheap domains, DNS, nameservers, email forwarding, WhoisGuard/privacy, or Namecheap CLI output.

## Command and setup

Installed package: `namecheap-python[cli]`

Primary command:

```bash
namecheap-cli --help
```

The package may expose `namecheap-dns-tui`, but use `namecheap-cli` for command-line management.

First-time setup:

```bash
namecheap-cli config init
```

Required credentials usually include:

- API key
- Username
- API user, usually same as username
- Client IP, if required by Namecheap API access controls
- Sandbox mode, only for testing

Config file:

```text
~/.config/namecheap/config.yaml
```

Environment variable setup:

```bash
export NAMECHEAP_API_KEY="your-api-key"
export NAMECHEAP_USERNAME="your-username"
export NAMECHEAP_API_USER="your-username"
export NAMECHEAP_CLIENT_IP="auto"
export NAMECHEAP_SANDBOX="false"
```

Never ask the user to paste secrets unless required. Prefer checking whether credentials are configured without displaying secret values.

## Safety workflow for DNS changes

Before changing DNS records, export the current records:

```bash
namecheap-cli dns export example.com --format yaml > example.com-backup.yaml
```

Then list current records and confirm the intended change when it is destructive or could affect production traffic:

```bash
namecheap-cli dns list example.com
```

DNS edits are applied through the Namecheap API and may take time to propagate.

## Common commands

### Domains

```bash
namecheap-cli domain list
namecheap-cli domain info example.com
namecheap-cli domain check example.com anotherdomain.io
```

### DNS records

```bash
namecheap-cli dns list example.com
namecheap-cli dns list example.com --type A
namecheap-cli dns list example.com --type CNAME
namecheap-cli dns export example.com --format yaml > example.com-dns.yaml
```

### Add DNS records

```bash
namecheap-cli dns add example.com A @ 192.0.2.1
namecheap-cli dns add example.com AAAA @ "2001:db8::1"
namecheap-cli dns add example.com CNAME www target.example.com
namecheap-cli dns add example.com TXT @ "v=spf1 include:_spf.google.com ~all"
namecheap-cli dns add example.com MX @ mail.example.com --priority 10
namecheap-cli dns add example.com URL301 old https://new-site.com
namecheap-cli dns add example.com CNAME blog target.example.com --ttl 300
```

Supported add types:

```text
A, AAAA, CNAME, MX, TXT, NS, URL, URL301, FRAME
```

### Delete DNS records

```bash
namecheap-cli dns delete example.com --type A --name @
namecheap-cli dns delete example.com --value "old-verification-token"
namecheap-cli dns delete example.com --type TXT --name @ --yes
```

Avoid `--yes` unless the user has explicitly approved the deletion.

### Nameservers

```bash
namecheap-cli dns nameservers example.com
namecheap-cli dns set-nameservers example.com ns1.cloudflare.com ns2.cloudflare.com
namecheap-cli dns reset-nameservers example.com
```

### Email forwarding

```bash
namecheap-cli dns email-forwarding example.com
namecheap-cli dns set-email-forwarding example.com info:me@example.com support:help@example.com
```

### Privacy / WhoisGuard

```bash
namecheap-cli privacy list
namecheap-cli privacy enable example.com forwarding-email@example.com
namecheap-cli privacy disable example.com
```

### Output formats

```bash
namecheap-cli --output json domain list
namecheap-cli --output yaml dns list example.com
namecheap-cli --output csv dns list example.com
```

## Validation checklist

- Confirm the target domain is correct.
- Export DNS records before making DNS changes.
- For delete, nameserver, privacy, or email-forwarding changes, get explicit confirmation unless the user already clearly approved the exact operation.
- Prefer global output flags such as `namecheap-cli --output json ...` or `namecheap-cli --output yaml ...` when parsing results.
- Do not print API keys or credential values in responses.
