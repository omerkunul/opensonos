import CommonCrypto
import Foundation
import Security

/// The cryptography an AirPlay (RAOP) receiver needs to talk to Apple senders:
/// answering the OPTIONS `Apple-Challenge`, unwrapping the AES key from the ANNOUNCE SDP,
/// and decrypting the AES-128-CBC audio packets.
///
/// `Apple-Response` and the key-unwrap are signed/decrypted with the RSA private key that
/// Apple shipped in the AirPort Express (extracted by James Laird and used by every open
/// AirPlay receiver since — shairport, shairplay, AirConnect). It is interop plumbing, not a
/// secret of ours; it only lets this Mac present itself to senders as a genuine AirPlay target.
enum AirPlayCrypto {
    /// PKCS#1 DER (base64) of the published AirPort Express 2048-bit RSA private key.
    private static let privateKeyB64 = "MIIEpQIBAAKCAQEA59dE8qLieItsH1WgjrcFRKj6eUWqi+bGLOX1HL3U3GhC/j0Qg90u3sG/1CUtwC5vOYvfDmFI6oSFXi5ELabWJmT2dKHzBJKa3k9ok+8t9ucRqMd6DZHJ2YCCLlDRKSKv6kDqnw4UwPdpOMXziC/AMj3Z/lUVX1G7WSHCAWKf1zNS1eLvqr+boEjXuBOitnZ/bDzPHrTOZz0Dew0uowxf/+sG+NCK3eQJVxqcaJ/vEHKIVd2M+5qL71yJQ+87X6oV3eaYvt3zWZYD6z5vYTcrtij2VZ9Zmni/UAaHqn9JdsBWLUEpVviYnhimNVvYFZeCXg/IdTQ+x4IRdiXNv5hEewIDAQABAoIBAQDl8Axy9XfWBLmkzkEiqoSwF0PsmVrPzH9KsnwLGH+QZlvjWd8SWYGN7u1507HvhF5N3drJoVU3O14nDY4TFQAaLlJ9VM35AApXaLyY1ERrN7u9ALKd2LUwYhM7Km539O4yUFYikE2nIPscEsA5ltpxOgUGCY7b7ez5NtD6nL1ZKauw7aNXmVAvmJTcuPxWmoktF3gDJKK2wxZuNGcJE0uFQEG4Z3BrWP7yoNuSK3dii2jmlpPHr0O/KnPQtzI3eguhe0TwUem/eYSdyzMyVx/YpwkzwtYL3sR5k0o9rKQLtvLzfAqdBxBurcizaaA/L0HIgAmOit1GJA2saMxTVPNhAoGBAPfgv1oeZxgxmotiCcMXFEQEWflzhWYTsXrhUIuz5jFua39GLS99ZEErhLdrwj8rDDViRVJ5skOp9zFvlYAHs0xh92ji1E7V/ysnKBfsMrPkk5KSKPrnjndMoPdevWnVkgJ5jxFuNgxkOLMuG9i53B4yMvDTCRiIPMQ++N2iLDaRAoGBAO9v//mU8eVkQaoANf0ZoMjW8CN4xwWA2cSEIHkd9AfFkftuv8oyLDCG3ZAf0vrhrrtkrfa7ef+AUb69DNggq4mHQAYBp7L+k5DKzJrKuO0r+R0YbY9pZD1+/g9dVt91d6LQNepUE/yY2PP5CNoFmjedpLHMOPFdVgqDzDFxU8hLAoGBANDrr7xAJbqBjHVwIzQ4To9pb4BNeqDndk5Qe7fT3+/H1njGaC0/rXE0Qb7q5ySgnsCb3DvAcJyRM9SJ7OKlGt0FMSdJD5KG0XPIpAVNwgpXXH5MDJg09KHeh0kXo+QA6viFBi21y340NonnEfdf54PX4ZGS/Xac1UK+pLkBB+zRAoGAf0AY3H3qKS2lMEI4bzEFoHeK3G895pDaK3TFBVmD7fV0Zhov17fegFPMwOII8MisYm9ZfT2Z0s5Ro3s5rkt+nvLAdfC/PYPKzTLalpGSwomSNYJcB9HNMlmhkGzc1JnLYT4iyUyx6pcZBmCd8bD0iwY/FzcgNDaUmbX9+XDvRA0CgYEAkE7pIPlE71qvfJQgoA9em0gILAuE4Pu13aKiJnfft7hIjbK+5kyb3TysZvoyDnb3HOKvInK7vXbKuU4ISgxB2bB3HcYzQMGsz1qJ2gG0N5hvJpzwwhbhXqFKA4zaaSrw622wDniAK5MlIE0tIAKKP4yxNGjoD2QYjhBGuhvkWKY="

    nonisolated(unsafe) private static let privateKey: SecKey? = {
        guard let der = Data(base64Encoded: privateKeyB64) else { return nil }
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 2048,
        ]
        return SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil)
    }()

    static var isAvailable: Bool { privateKey != nil }

    /// The `Apple-Response` for an OPTIONS `Apple-Challenge`: RSA-sign (PKCS#1 v1.5, with no
    /// DigestInfo prefix) the 16-byte challenge followed by this receiver's IP and hardware id,
    /// zero-padded to 32 bytes. The result is base64 with the `=` padding stripped, as senders expect.
    static func appleResponse(challenge: Data, ip: Data, mac: Data) -> String? {
        var block = challenge
        block.append(ip)
        block.append(mac)
        while block.count < 32 { block.append(0) }
        guard let key = privateKey else { return nil }
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            key, .rsaSignatureDigestPKCS1v15Raw, block as CFData, &error
        ) as Data? else { return nil }
        return signature.base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    /// Unwraps the RSA/OAEP-wrapped AES-128 key carried in the SDP `a=rsaaeskey`.
    static func unwrapAESKey(_ wrapped: Data) -> Data? {
        guard let key = privateKey else { return nil }
        var error: Unmanaged<CFError>?
        return SecKeyCreateDecryptedData(key, .rsaEncryptionOAEPSHA1, wrapped as CFData, &error) as Data?
    }

    /// Decrypts an AirPlay audio payload: AES-128-CBC over whole 16-byte blocks only, the IV
    /// reset to the session IV for every packet, any trailing partial block left in the clear.
    static func decryptAudio(_ data: Data, key: Data, iv: Data) -> Data {
        let whole = data.count - (data.count % 16)
        guard whole > 0, key.count == 16, iv.count == 16 else { return data }
        var out = Data(count: whole)
        var moved = 0
        let status = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128),
                                CCOptions(0),                         // CBC, no padding
                                keyPtr.baseAddress, key.count,
                                ivPtr.baseAddress,
                                inPtr.baseAddress, whole,
                                outPtr.baseAddress, whole, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return data }
        out.removeSubrange(moved..<out.count)
        if whole < data.count { out.append(data.suffix(data.count - whole)) }
        return out
    }
}
