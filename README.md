# StikJIT

A **work-in-progress** on-device JIT enabler.

The [SideStore VPN](https://github.com/SideStore/SideStore/releases/download/0.1.1/SideStore.conf) is required. This allows the device to connect to itself.

Powered by [idevice](https://github.com/jkcoxson/idevice) and [Emotional Mangling Proxy](https://github.com/SideStore/em_proxy).

All dependencies remain under their original licenses.

## TODO List  

- [X] Integrate `em_proxy`  
- [X] Compile idevice 
- [X] Implement heartbeat
- [ ] Mount the developer image     
- [X] Retrieve and filter installed apps by `get-task-allow`  
- [X] Enable JIT for selected apps  
- [X] Design and implement a user-friendly UI (Done for now)
- [ ] Write comprehensive documentation  
- [ ] Prepare and release the initial version  
