# Canary

A second bundle (`ghcr.io/morzecrew/dotdash-canary`, released with dotdash)
for a machine inside the network you worry about: it connects as a client and
fails `doctor` when it cannot get through. Needs Docker, sops, age and morzer
(`bootstrap.sh`), and no open port.

1. On the server, add a `<uuid> canary` line to `vless_clients`, then run
   what this prints on the canary machine:

    ```sh
    sudo morzer task run canary-config --output -- canary
    ```

2. On the canary machine:

    ```sh
    sudo morzer notify target add https://hooks.example/morzer
    sudo morzer config set doctor.schedule='*:0/10'
    sudo morzer task run measure --output -- 50    # each transport 50 times, as JSON
    ```

Profiles `xhttp` and `xhttp-reality` check those transports too. A canary
watches one server; `canary-config` prints how to point it at the others.
