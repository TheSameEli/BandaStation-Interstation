/* In-process Windows CNG adapter for the local transit test deployment.
 * No separate process or network service. Journal writes use server-owned relative paths.
 * Build: zig cc -target x86-windows-gnu -shared transit_crypto.c -lbcrypt -O2 -o transit_crypto.dll
 */
#include <windows.h>
#include <bcrypt.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <wchar.h>

/* Publish an immutable UTF-8 file only after flushing its complete contents.
 * No REPLACE_EXISTING: a replay can never overwrite a previous durable decision.
 */
__declspec(dllexport) const char *transit_write(int argc, const char **argv) {
    WCHAR relative[MAX_PATH], absolute[2048], directory[2052], temporary[2100];
    HANDLE file = INVALID_HANDLE_VALUE;
    unsigned char random[8];
    DWORD written = 0;
    int published = 0;
    if (argc != 2 || !argv[0] || !argv[1]) return "0";
    const char *path = argv[0], *body = argv[1];
    size_t path_size = strlen(path), size = strlen(body);
    if (!path_size || path_size > MAX_PATH - 40 || path[0] == '/' || path[0] == '\\' || strchr(path, ':') || strstr(path, "..") || size > 16777216) return "0";
    if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, relative, MAX_PATH)) return "0";
    for (WCHAR *cursor = relative; *cursor; ++cursor) if (*cursor == L'/') *cursor = L'\\';
    DWORD length = GetFullPathNameW(relative, 2048, absolute, NULL);
    if (!length || length >= 2048 || absolute[1] != L':') return "0";
    // Extended absolute paths also work in deeply nested Codex workspaces.
    swprintf(directory, 2052, L"\\\\?\\%ls", absolute);
    for (WCHAR *cursor = directory + 7; *cursor; ++cursor) {
        if (*cursor != L'\\') continue;
        *cursor = 0;
        if (!CreateDirectoryW(directory, NULL) && GetLastError() != ERROR_ALREADY_EXISTS) return "0";
        *cursor = L'\\';
    }
    if (BCryptGenRandom(NULL, random, sizeof(random), BCRYPT_USE_SYSTEM_PREFERRED_RNG) < 0) return "0";
    swprintf(temporary, 2100, L"%ls.tmp-%02x%02x%02x%02x%02x%02x%02x%02x", directory, random[0], random[1], random[2], random[3], random[4], random[5], random[6], random[7]);
    file = CreateFileW(temporary, GENERIC_WRITE, 0, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_WRITE_THROUGH, NULL);
    if (file == INVALID_HANDLE_VALUE) return "0";
    int complete = WriteFile(file, body, (DWORD)size, &written, NULL) && written == size && FlushFileBuffers(file);
    CloseHandle(file);
    if (complete) published = MoveFileExW(temporary, directory, MOVEFILE_WRITE_THROUGH);
    if (!published) DeleteFileW(temporary);
    return published ? "1" : "0";
}

static int calculate(const char *key, const char *body, unsigned char out[32]) {
    BCRYPT_ALG_HANDLE algorithm = NULL;
    BCRYPT_HASH_HANDLE hash = NULL;
    int ok = 0;
    if (strlen(key) > 1024 || strlen(body) > 32768) return 0;
    if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, NULL,
                                    BCRYPT_ALG_HANDLE_HMAC_FLAG) < 0) goto cleanup;
    if (BCryptCreateHash(algorithm, &hash, NULL, 0, (PUCHAR)key,
                        (ULONG)strlen(key), 0) < 0) goto cleanup;
    if (BCryptHashData(hash, (PUCHAR)body, (ULONG)strlen(body), 0) < 0) goto cleanup;
    if (BCryptFinishHash(hash, out, 32, 0) < 0) goto cleanup;
    ok = 1;
cleanup:
    if (hash) BCryptDestroyHash(hash);
    if (algorithm) BCryptCloseAlgorithmProvider(algorithm, 0);
    return ok;
}

__declspec(dllexport) const char *transit_sign(int argc, const char **argv) {
    static char output[65];
    static const char hex[] = "0123456789abcdef";
    unsigned char hash[32];
    if (argc != 2 || !calculate(argv[0], argv[1], hash)) return "ERROR";
    for (int i = 0; i < 32; ++i) {
        output[2*i] = hex[hash[i] >> 4];
        output[2*i+1] = hex[hash[i] & 15];
    }
    output[64] = 0;
    SecureZeroMemory(hash, sizeof(hash));
    return output;
}

__declspec(dllexport) const char *transit_verify(int argc, const char **argv) {
    if (argc != 3 || strlen(argv[2]) != 64) return "0";
    const char *expected = transit_sign(2, argv);
    if (strlen(expected) != 64) return "0";
    volatile unsigned int mismatch = 0;
    for (int i = 0; i < 64; ++i) mismatch |= (unsigned char)expected[i] ^ (unsigned char)argv[2][i];
    return mismatch == 0 ? "1" : "0";
}
