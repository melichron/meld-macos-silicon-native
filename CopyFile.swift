// SPDX-License-Identifier: GPL-2.0-or-later
import Darwin
import Foundation

private func checked(_ code: Int32) throws -> Int32 {
    guard code >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    return code
}

// Work relative to open directories so a symlink cannot redirect a copy.
private func parent(_ root: URL, components: ArraySlice<String>, create: Bool) throws -> Int32 {
    var fd = try checked(open(root.path, O_RDONLY | O_DIRECTORY))
    do {
        for component in components {
            if create && mkdirat(fd, component, 0o755) < 0 && errno != EEXIST {
                _ = try checked(-1)
            }
            let next = try checked(openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW))
            close(fd)
            fd = next
        }
        return fd
    } catch { close(fd); throw error }
}

func copyMissing(_ path: String, from source: URL, to destination: URL) throws {
    let parts = path.components(separatedBy: "/")
    guard let name = parts.last, !parts.contains(where: { ["", ".", ".."].contains($0) }) else {
        throw Problem(tr("Некорректный относительный путь."))
    }
    let src = try parent(source, components: parts.dropLast(), create: false)
    defer { close(src) }
    let input = try checked(openat(src, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK))
    defer { close(input) }
    var info = stat()
    _ = try checked(fstat(input, &info))
    guard info.st_mode & S_IFMT == S_IFREG else { throw Problem(tr("Источник должен быть обычным файлом.")) }

    let dst = try parent(destination, components: parts.dropLast(), create: true)
    defer { close(dst) }
    let temporary = ".meldmac-" + UUID().uuidString
    let output = try checked(openat(dst, temporary, O_WRONLY | O_CREAT | O_EXCL, 0o600))
    defer { close(output); unlinkat(dst, temporary, 0) }
    _ = try checked(fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_ALL)))
    _ = try checked(fsync(output))
    // Publish only a complete file. A newly appeared destination wins.
    _ = try checked(renameatx_np(dst, temporary, dst, name, UInt32(RENAME_EXCL)))
}
