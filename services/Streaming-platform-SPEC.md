# Streaming Platform Upload - Specification

## Project Overview

- **Project Name**: streaming-platform-upload
- **Type**: Video Upload Service with NextJS
- **Core Functionality**: Event-driven video upload platform supporting CMAF format with S3/MinIO storage
- **Target Users**: Content creators uploading videos (300MB-1GB, ~30/day average)

## Technical Stack

- **Frontend/Backend**: NextJS 14 (App Router)
- **Styling**: CSS Modules with custom properties
- **Storage**: AWS S3 (production) / MinIO (local testing)
- **Events**: EventEmitter-based architecture
- **Video Format**: CMAF (Common Media Application Format)
- **Testing**: Jest + ts-jest (unit tests)

## Architecture

### Event-Driven System

```
Upload Request → Events → Handlers → Storage Layer
```

**Events:**
- `upload.started` - Upload initiated
- `upload.progress` - Progress updates
- `upload.completed` - Upload finished
- `upload.failed` - Upload failed
- `video.processing` - Video processing started
- `video.ready` - Video ready for streaming
- `video.transcoded` - Transcoding completed
- `video.thumbnail.generated` - Thumbnail successfully extracted
- `video.thumbnail.fallback` - Fallback thumbnail generated (extraction failed)

### Layer Structure

```
┌─────────────────────────────────────────┐
│           Presentation Layer            │
│         (NextJS Pages/Components)        │
├─────────────────────────────────────────┤
│           Application Layer             │
│     (API Routes, Event Controllers)     │
├─────────────────────────────────────────┤
│            Service Layer               │
│   (Upload Service, Video Service)       │
├─────────────────────────────────────────┤
│         Integration Layer               │
│   (External System Connectors)          │
├─────────────────────────────────────────┤
│          Storage Layer                 │
│     (S3 Adapter, MinIO Adapter)        │
└─────────────────────────────────────────┘
```

## UI/UX Specification

### Layout Structure

**Page Sections:**
1. Header (64px height) - Logo, navigation
2. Main Content - Upload area, video list
3. Footer (48px height) - Copyright, links

**Responsive Breakpoints:**
- Mobile: < 768px
- Tablet: 768px - 1024px
- Desktop: > 1024px

### Visual Design

**Color Palette:**
- Background: #0d0d0d (dark)
- Surface: #1a1a1a
- Surface Elevated: #262626
- Primary: #00adef (Vimeo blue accent)
- Primary Hover: #33bdff
- Text Primary: #ffffff
- Text Secondary: #a0a0a0
- Success: #00c853
- Error: #ff5252
- Border: #333333

**Typography:**
- Font Family: "Inter", -apple-system, BlinkMacSystemFont, sans-serif
- Headings: 700 weight
  - H1: 32px
  - H2: 24px
  - H3: 18px
- Body: 400 weight, 14px
- Small: 12px

**Spacing System:**
- Base unit: 8px
- xs: 4px, sm: 8px, md: 16px, lg: 24px, xl: 32px, xxl: 48px

**Visual Effects:**
- Border radius: 8px (cards), 4px (buttons), 50% (avatars)
- Shadows: 0 4px 24px rgba(0, 0, 0, 0.4)
- Transitions: 200ms ease-out

### Components

**Upload Dropzone:**
- Dashed border (#333), 2px
- Hover: border color #00adef, background rgba(0, 172, 239, 0.05)
- Active (dragging): border solid, background rgba(0, 172, 239, 0.1)
- Icon: Upload cloud, 48px
- Text: "Drag and drop your video here" + "or click to browse"

**Upload Progress Card:**
- Thumbnail preview (16:9 aspect ratio)
- File name, size
- Progress bar (height 4px, rounded)
- Status badges: uploading, processing, ready, error
- Actions: cancel, retry, delete

**Video List:**
- Grid layout (3 columns desktop, 2 tablet, 1 mobile)
- Cards with thumbnail, title, duration, status
- Hover: scale 1.02, shadow increase

**Buttons:**
- Primary: background #00adef, text white
- Secondary: background transparent, border #333
- Disabled: opacity 0.5, cursor not-allowed

## Functionality Specification

### Core Features

1. **Video Upload**
   - True multipart upload via S3/MinIO Multipart Upload protocol
   - Client-side file splitting: 10MB chunks via `File.slice()`
   - Three-phase flow: initiate → upload chunks → complete
   - Small-file fallback: files ≤ 10MB use direct `PutObject` (S3 requires ≥ 5MB per part in multipart)
   - Drag & drop + click to browse
   - File validation (CMAF formats: .mp4, .m4v, .mov, .m3u8)
   - Maximum file size: 2GB

2. **Progress Tracking**
   - Real-time progress updates via events
   - Upload speed display
   - Estimated time remaining
   - Visual progress bar

3. **Storage Adapters**
   - `S3Adapter` (production) — uses `@aws-sdk/client-s3` with native multipart commands
   - `MinIOAdapter` (local development/testing) — uses `minio` Client for listing/signing/deletion; uses an internal `S3Client` with `forcePathStyle: true` for multipart (the `minio` package does not expose multipart APIs publicly; MinIO is S3-compatible)
   - Interface: `IStorageAdapter`

4. **External System Integration**
   - IntegrationLayer interface
   - Pre-defined connectors for common systems
   - Webhook support for notifications

5. **Event System**
   - Central EventEmitter
   - Typed events
   - Event history logging
   - Error event handling

6. **Automatic Thumbnail Generation**
   - Extracts frame at 2-second mark from uploaded video
   - Generates 640×360 JPEG thumbnail using FFmpeg
   - Stores thumbnail in same S3/MinIO bucket under `/thumbnails/` prefix
   - Non-blocking: extraction happens asynchronously after upload completes
   - **Fallback handling**: If extraction fails (timeout, unsupported codec, corrupted file, etc.), 
     generates dynamic placeholder image with video filename and upload date
   - Publishes events: `video.thumbnail.generated` (success) or `video.thumbnail.fallback` (failure)
   - Client receives real-time updates via EventEmitter
   - Thumbnail URL populated in video record once ready

### API Endpoints

#### Upload flow (three phases, must be called in order)

```
POST /api/upload
  Body (JSON): { filename: string, size: number, mimeType?: string }
  Response:    { sessionId: string, videoId: string, chunkSize: number, totalChunks: number }

POST /api/upload/chunk
  Body (FormData): sessionId, chunkIndex (0-based), chunk (Blob)
  Response:        { ok: true }

POST /api/upload/complete
  Body (JSON): { sessionId: string }
  Response:    { success: true, video: { id, filename, size, status, url } }
```

#### Other endpoints

```
GET    /api/videos         - List videos
GET    /api/videos/:id     - Get video details
DELETE /api/videos/:id     - Delete video
POST   /api/integrate      - External system integration
```

### Data Models

**Video:**
```typescript
interface Video {
  id: string;
  filename: string;
  originalName: string;
  size: number;
  status: 'uploading' | 'processing' | 'ready' | 'error';
  progress: number;
  createdAt: Date;
  updatedAt: Date;
  url?: string;
  thumbnailUrl?: string;
  thumbnailStatus?: 'pending' | 'ready' | 'failed';
}
```

**Upload Session:**
```typescript
interface UploadSession {
  id: string;
  videoId: string;
  totalChunks: number;
  uploadedChunks: number;
  chunkSize: number;
  totalSize: number;
  startedAt: Date;
  filename: string;
  uploadId: string;                               // from initiateMultipartUpload; empty for single-chunk files
  etags: { PartNumber: number; ETag: string }[];  // accumulated per uploadPart call
}
```

## CMAF Support

CMAF (Common Media Application Format) is supported through:
- Input formats: MP4, MOV, M4V, WebM
- Output: HLS (.m3u8) + MPEG-DASH
- Transcoding service integration point
- Storage of both video and manifest files

## Acceptance Criteria

1. User can drag & drop or browse to select video files
2. Upload progress displays in real-time, advancing per chunk
3. Chunked upload works for files up to 1GB via S3 Multipart Upload protocol
4. Files ≤ 10MB upload via direct `PutObject` (single-chunk fallback)
5. MinIO adapter works for local testing (uses S3-compatible multipart protocol)
6. S3 adapter configured for production
7. Events propagate correctly through the system
8. External integration layer is extensible
9. UI matches Vimeo-like aesthetic
10. Responsive design works on all breakpoints
11. Error states are handled gracefully
12. Unit tests cover multipart upload service logic
13. Thumbnail extraction succeeds for all valid video formats
14. Fallback image generated for unsupported/corrupted videos
15. Upload completes within 100ms, does not block on thumbnail extraction
16. Thumbnail available in storage within 2 seconds of upload completion
17. Client receives thumbnail events and updates UI in real-time
18. Thumbnail extraction errors are logged for debugging
