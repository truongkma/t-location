# StikJIT  

A **work-in-progress** on-device JIT enabler for iOS.  

## Requirements  
The [SideStore VPN](https://github.com/SideStore/SideStore/releases/download/0.1.1/SideStore.conf) is required. This allows the device to connect to itself.  

## Features  
- On-device Just-In-Time (JIT) compilation for supported apps.  
- Seamless integration with [`em_proxy`](https://github.com/SideStore/em_proxy) and [`idevice`](https://github.com/jkcoxson/idevice).  
- Native UI for managing JIT-enabling.  
- No data collection—ensuring full privacy.  

## Privacy Policy  
StikJIT **does not collect or store any user data.**  

## Compiling Instructions  

1. **Clone the repository:**  
   ```sh
   git clone https://github.com/0-Blu/StikJIT.git
   cd StikJIT
   ```

2. **Open in Xcode:**  
   Open `StikJIT.xcodeproj` in Xcode.  

3. **Build and Run:**  
   - Connect your iOS device.  
   - Select your device in Xcode.  
   - Build and run the project.  

## TODO List  
- [X] Integrate [`em_proxy`](https://github.com/SideStore/em_proxy)  
- [X] Compile [`idevice`](https://github.com/jkcoxson/idevice)  
- [X] Implement heartbeat  
- [X] Mount the developer image  
- [X] Retrieve and filter installed apps by `get-task-allow`  
- [X] Enable JIT for selected apps  
- [X] Design and implement a user-friendly UI *(Done for now)*  
- [ ] Write comprehensive documentation  
- [ ] Prepare and release the initial version  

## License  
StikJIT is licensed under **AGPL-3.0**. See [`LICENSE`](LICENSE) for details.  
