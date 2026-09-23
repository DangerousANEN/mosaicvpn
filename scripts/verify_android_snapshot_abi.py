"""Fail release packaging when the APK lacks native runtime for a Flutter ABI."""
import argparse
import zipfile


def verify(path):
    with zipfile.ZipFile(path) as archive:
        names = set(archive.namelist())
    abis = sorted(n.split('/')[1] for n in names if n.endswith('/libflutter.so'))
    if not abis:
        raise ValueError('APK has no Flutter native runtime')
    for abi in abis:
        for library in ('libflutter.so', 'libapp.so', 'libbox.so'):
            if f'lib/{abi}/{library}' not in names:
                raise ValueError(f'Missing {abi}/{library}')
    if 'arm64-v8a' not in abis:
        raise ValueError('Phone snapshot requires arm64-v8a')
    return abis


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('apk')
    args = parser.parse_args()
    print('Verified complete native ABI sets:', ', '.join(verify(args.apk)))
