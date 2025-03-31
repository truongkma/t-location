# StikJIT  

A **work-in-progress** on-device JIT enabler for iOS versions 17.4+ (excluding iOS 18.4 beta 1), powered by [`idevice`](https://github.com/jkcoxson/idevice).  
[![GitHub Release](https://img.shields.io/github/v/release/0-Blu/StikJIT?include_prereleases)](https://github.com/0-Blu/StikJIT/releases)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg?style=flat-square)](https://github.com/0-Blu/StikJIT/pulls)
[![GitHub License](https://img.shields.io/github/license/0-Blu/StikJIT?color=%23C96FAD&cache=none)](https://github.com/0-Blu/StikJIT/blob/main/LICENSE)
![GitHub Downloads (all assets, all releases)](https://img.shields.io/github/downloads/0-Blu/StikJIT/total)

## Requirements  
The [SideStore VPN](https://github.com/SideStore/SideStore/releases/download/0.1.1/SideStore.conf) is required. This allows the device to connect to itself.  

## Features  
- On-device Just-In-Time (JIT) compilation for supported apps via [`idevice`](https://github.com/jkcoxson/idevice).  
- Seamless integration with [`em_proxy`](https://github.com/SideStore/em_proxy).  
- Native UI for managing JIT-enabling.  
- No data collection—ensuring full privacy. 

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

## License  
StikJIT is licensed under **AGPL-3.0**. See [`LICENSE`](LICENSE) for details.  
