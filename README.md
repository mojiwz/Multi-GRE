# Vatan GRE Manager

A user-friendly multi GRE tunnel manager for Linux.

## Features

- Interactive CLI
- Iran -> Multiple Foreign GRE tunnels
- Foreign -> Iran GRE tunnels
- Automatic tunnel IP allocation
- Multiple independent GRE interfaces
- Tunnel connectivity testing
- GRE packet capture
- Traffic statistics
- Firewall configuration
- Connection monitoring
- systemd monitoring service
- Persistent tunnel configuration
- No hard-coded server IPs

## Requirements

- Linux
- Root access
- IPv4 public connectivity
- GRE protocol (IP protocol 47) allowed by your firewall/provider

Supported package managers:

- apt
- dnf
- yum

## Installation

Run as root:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/USERNAME/vatan-gre/main/install.sh)