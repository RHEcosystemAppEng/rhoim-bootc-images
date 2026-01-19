# RHOIM Inference Platform – Repo Skeleton (OpenShift/K8s/off‑K8s)

A production‑ready skeleton to ship **images** using **bootc**, runnable on **OpenShift**, **vanilla Kubernetes**, and **off‑Kubernetes** (systemd), relying on **RHAIIS** for GPU enablement. Focus: help customers **transition to RHOAI**.

## Documentation

- **[Podman Desktop Development Workflow](docs/PODMAN_DESKTOP_DEVELOPMENT.md)** - Guide for setting up and using Podman Desktop for local development and testing
- **[Cloud Deployment Guide](docs/CLOUD_DEPLOYMENT.md)** - Instructions for deploying bootc images to Azure, AWS, and other cloud platforms

=== Final Summary ===
✅✅✅ AMI CREATION COMPLETE! ✅✅✅

AMI ID: ami-07a72249ce1edfd14
Snapshot ID: snap-072a32f78e3da88fd
Volume ID: vol-025cf0c2df8922452


Snapshot: snap-072a32f78e3da88fd
Creating new AMI with ENA explicitly enabled...
✅ New AMI created with ENA: ami-09d7086a3c731421a

AMI ID: ami-09d7086a3c731421a
ENA Support: True
Boot Mode: uefi

ENA support confirmed! Launching GPU instance...
✅ GPU Instance launched successfully!
Instance ID: i-0cf733bcc00bdad59

Waiting for instance to be running...

=== Instance Details ===
-------------------------
|   DescribeInstances   |
+-----------------------+
|  i-0cf733bcc00bdad59  |
|  running              |
|  44.203.185.174       |
|  g4dn.xlarge          |
+-----------------------+
