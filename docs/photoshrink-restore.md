## PhotoShrink Restore integration

First milestone: local encrypted exact-recovery vault integrated into Little Memories' Memory Center.

- Uses photo_manager for selection.
- Archives original bytes; uses gzip only when the payload becomes smaller.
- Encrypts payloads with AES-256-GCM and a fresh nonce per object.
- Stores the archive key in Android secure storage.
- Verifies the persisted archive by decrypting and comparing SHA-256 and byte length.
- Restores into app-private storage and offers the Android share sheet for export.
- Never deletes or overwrites source photos.

Archive object v1: four ASCII bytes PSR1, a four-byte big-endian header length, UTF-8 JSON header, then AES-256-GCM ciphertext. The header contains version, original filename/size/hash, codec, nonce, authentication tag and timestamp.

Limitations: Google Drive is not implemented yet; lossless archiving may not shrink JPEG/HEIC; app uninstall or device loss can destroy app-private archive/key data; no original-deletion workflow is included. Next steps are analyzer/build validation, archive corruption/round-trip tests, optimized viewing copies, cloud backup with remote verification and recoverable key management. Only add deletion after those safety gates pass.
