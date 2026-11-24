# Project keys

Public keys of the project builds at <https://mirror.prepaid-host.io/hvpatch/>.

| File | What | Fingerprint |
| --- | --- | --- |
| `manifest.pub` | minisign public key; nodes check every manifest and revocation list against it | key id `64C12AABF4A1E0D4` |
| `module-cert.der` | X.509 certificate of the module signing key (enroll as MOK under Secure Boot) | SHA-256 `65:21:D8:87:79:53:C4:AF:5C:50:EC:8F:68:65:68:DB:9B:04:E0:32:2A:4F:8C:23:BB:A6:42:24:82:66:E6:AE` |

Check:

```bash
head -1 manifest.pub                       # untrusted comment: minisign public key 64C12AABF4A1E0D4
openssl x509 -inform DER -in module-cert.der -noout -fingerprint -sha256
```

Rotation and what to do if a key leaks: [docs/key-management.md](../docs/key-management.md).
