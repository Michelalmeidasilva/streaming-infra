# AWS S3 Storage Module

## Overview

This module provisions the Amazon S3 object storage infrastructure for the Video on Demand platform, based on cost specifications and video volumetry.

```
┌──────────────────────────────────────┐
│     streaming-platform-upload        │
│    (Uploads raw video chunks)        │
└──────────────────────────────────────┘
                  │
                  ▼
         ┌──────────────────┐
         │     S3 Bucket    │
         │                  │
         │  raw/            │
         │  transcoded/     │
         └──────────────────┘
                  ▲
                  │
┌──────────────────────────────────────┐
│        streaming-transcode           │
│   (Downloads raw, uploads chunks)    │
└──────────────────────────────────────┘
```

## Architecture Decisions Summary

During the initial setup, the following architectural choices were made for this S3 configuration based on cost-efficiency and security for a VOD platform:

- **Bucket Type**: `General purpose`. Chosen over `Directory` because Directory buckets do not support lifecycle transitions to cheaper storage classes (IA/Glacier), which is mandatory for managing long-term video costs.
- **Bucket Namespace**: `Account Regional namespace`. Recommended to avoid global naming collisions and ensure the bucket name remains secure and unique within the AWS account and region.
- **Object Ownership**: `ACLs disabled`. Centralizes security through IAM and Bucket Policies, preventing permission collisions when the backend uploads files.
- **Public Access**: `Block all public access`. Enforced to prevent direct video downloads and massive egress costs. Delivery will be handled securely via CloudFront (CDN) with Origin Access Control (OAC).
- **Versioning**: `Disabled`. Since video files average 1GB+, keeping overwritten/deleted versions would silently double or triple storage costs.
- **Encryption**: `SSE-S3`. Free encryption at rest managed by S3, avoiding the high API costs associated with `SSE-KMS` when fetching thousands of video chunks (HLS/DASH).

## Quick Start

### Usage with Terraform

To use this module in your Terraform infrastructure, add the following to your `main.tf`:

```hcl
module "storage_s3" {
  source      = "./modules/storage-s3"
  bucket_name = "vod-streaming-storage-2026"
  environment = "production"
}
```

Deploy the infrastructure:

```bash
terraform init
terraform apply
```

## Storage Classes and Lifecycle Rules

To optimize costs, this module configures lifecycle rules automatically:

1. **Raw Videos (`raw/`)**: Files in this prefix expire and are deleted after **90 days**.
2. **Transcoded Videos (`transcoded/`)**: Files in this prefix transition to the **Standard-IA** (Infrequent Access) storage class after **60 days** to save 50% on storage costs.

## Security

- **Public Access**: Blocked entirely. The bucket is not exposed to the internet directly.
- **Encryption**: Server-Side Encryption with Amazon S3 managed keys (SSE-S3) is enabled by default.
- **Versioning**: Disabled by default to prevent unexpected costs from retained file versions.

## Alternative: Manual Setup via AWS Console

If you prefer to create this structure manually through the AWS Console, follow these steps:

### 1. Create the Bucket
1. Open the [Amazon S3 Console](https://s3.console.aws.amazon.com/s3/home).
2. Click **Create bucket**.
3. **Bucket name**: Choose a unique name (e.g., `vod-storage-2026`).
4. **AWS Region**: Select `US East (N. Virginia) us-east-1`.
5. **Object Ownership**: Keep **ACLs disabled**.
6. **Block Public Access**: Keep **Block all public access** checked.
7. **Bucket Versioning**: Keep **Disable**.
8. **Default encryption**: Keep **SSE-S3** enabled.
9. Click **Create bucket**.

### 2. Create Prefixes (Folders)
1. Open your newly created bucket.
2. Click **Create folder**.
3. Create a folder named `raw/`.
4. Create another folder named `transcoded/`.

### 3. Configure Lifecycle Rules
1. Go to the **Management** tab of your bucket.
2. Under **Lifecycle rules**, click **Create lifecycle rule**.
   
**Rule 1: Transition Transcoded Videos**
- **Rule name**: `Transition-Transcoded-Videos-To-IA`
- **Scope**: *Limit the scope of this rule using one or more filters*
- **Prefix**: `transcoded/`
- **Action**: Check **Move current versions of objects between storage classes**.
- **Transition**: Select **Standard-IA** and type **60** for days after object creation.

**Rule 2: Expire Raw Videos**
- **Rule name**: `Expire-Raw-Videos`
- **Scope**: *Limit the scope of this rule using one or more filters*
- **Prefix**: `raw/`
- **Action**: Check **Expire current versions of objects**.
- **Expiration**: Type **90** for days after object creation.
