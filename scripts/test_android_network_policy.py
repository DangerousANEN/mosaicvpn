from pathlib import Path
import subprocess
root = Path('/home/kasm-user/.gradle/wrapper/dists/gradle-9.1.0-all')
lib = next(root.glob('*/gradle-9.1.0/lib'))
stdlib = next(lib.glob('kotlin-stdlib-*.jar'))
base = Path('/tmp/mosaic-handover-test')
sources = [base/'UnderlyingNetworkPolicy.kt', base/'UnderlyingNetworkPolicyTest.kt']
subprocess.run(['java','-Xmx512m','-cp',str(lib/'*'),'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler','-no-stdlib','-no-reflect','-classpath',str(stdlib),*[str(x) for x in sources],'-d',str(base/'policy.jar')],check=True)
subprocess.run(['java','-cp',f'{base}/policy.jar:{stdlib}','ru.mosaicvpn.mosaic_vpn.UnderlyingNetworkPolicyTestKt'],check=True)
