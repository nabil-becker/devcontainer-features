"""Run inside a node container by test/facilitator/mesh_flow.sh: a client that dials the hub's private SLIM
listener with a certificate of its own and sends the hub's peers part one envelope.

    mesh_impostor.py <hub host:port> <server_name> <cert> <key> <bundle> <mesh secret file> <hub node> <envelope file>

Prints CONNECT-REFUSED when the listener refused the certificate (lock one), SENT when the envelope was handed
over (then lock two decides, in the hub's mesh/refused.log), SEND-FAILED otherwise."""
import asyncio
import datetime
import sys

sys.path.insert(0, "/opt/facilitator/lib")
import slim_bindings as sb  # noqa: E402


async def main(addr, sni, cert, key, bundle, secret_file, hub, env_file) -> int:
    sb.initialize_with_configs(sb.new_runtime_config(), sb.new_tracing_config_with("error", False, False, []),
                               [sb.new_service_config()])
    svc = sb.get_global_service()
    tls = sb.TlsClientConfig(insecure=False, insecure_skip_verify=False, source=sb.TlsSource.FILE(cert=cert, key=key),
                             ca_source=sb.CaSource.FILE(path=bundle), include_system_ca_certs_pool=False,
                             tls_version="tls1.3")
    base = sb.new_insecure_client_config(f"https://{addr}")
    cfg = sb.ClientConfig(**{**vars(base), "tls": tls, "server_name": sni})
    try:
        conn = await asyncio.wait_for(svc.connect_async(cfg), 10)
    except Exception as e:                     # noqa: BLE001
        print("CONNECT-REFUSED", type(e).__name__, str(e)[:160].replace("\n", " "))
        return 0
    me = sb.Name("agntcy", "facilitator-node", "impostor")
    app = svc.create_app_with_secret(me, open(secret_file).read().strip())
    await app.subscribe_async(me, conn)
    td = datetime.timedelta
    c = sb.SessionConfig(session_type=sb.SessionType.POINT_TO_POINT, max_retries=3, interval=td(milliseconds=700),
                         metadata={}, mls_settings=None)
    try:
        s = await asyncio.wait_for(app.create_session_and_wait_async(c, sb.Name("agntcy", "facilitator-node", hub)), 10)
        h = await s.publish_async(open(env_file, "rb").read(), None, None)
        await h.wait_async()
        print("SENT")
    except Exception as e:                     # noqa: BLE001
        print("SEND-FAILED", type(e).__name__, str(e)[:160].replace("\n", " "))
    await asyncio.sleep(1)
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main(*sys.argv[1:9])))
