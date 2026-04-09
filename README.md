# useful_scripts
Useful scripts for various purposes

Allow user to deal with docker: `sudo usermod -aG docker $USER`

Edit docker config `sudo nano /etc/docker/daemon.json` and add mirrors, so that it becomes looking like
```json
{
    "runtimes": {
        "nvidia": {
            "args": [],
            "path": "nvidia-container-runtime"
        }
    },
    "registry-mirrors": ["https://dh-mirror.gitverse.ru"]
}
```
