<div align="center">
   <img width="217" height="217" src="/assets/StikJIT_Rounded_Corners.png" alt="Logo">
</div>
   

<div align="center">
  <h1><b>StikDebug</b></h1>
  <p><i> An on-device debugger/JIT enabler for iOS versions 17.4+ (17.4-18.5b1 (latest)), excluding iOS 18.4 beta 1 (22E5200), powered by <a href="https://github.com/jkcoxson/idevice">idevice</a> </i></p>
</div>
<h6 align="center">

| <p align="center"><picture><source media="(prefers-color-scheme: dark)" srcset="https://github.com/neoarz/StikJIT/blob/main/assets/views/dark/HomeScreen.PNG?raw=true"><source media="(prefers-color-scheme: light)" srcset="https://github.com/neoarz/StikJIT/blob/main/assets/views/light/HomeScreen.PNG?raw=true"><img alt="Sources" src="https://github.com/neoarz/StikJIT/blob/main/assets/views/dark/HomeScreen.PNG?raw=true" width="200"></picture></p> | <p align="center"><picture><source media="(prefers-color-scheme: dark)" srcset="https://github.com/neoarz/StikJIT/blob/main/assets/views/dark/AppsList.PNG?raw=true"><source media="(prefers-color-scheme: light)" srcset="https://github.com/neoarz/StikJIT/blob/main/assets/views/light/AppsList.PNG?raw=true"><img alt="Store" src="https://github.com/neoarz/StikJIT/blob/main/assets/views/dark/AppsList.PNG?raw=true" width="200"></picture></p> | <p align="center"><picture><source media="(prefers-color-scheme: dark)" srcset="https://github.com/neoarz/StikJIT/blob/main/assets/views/dark/Settings.PNG?raw=true"><source media="(prefers-color-scheme: light)" srcset="https://github.com/neoarz/StikJIT/blob/main/assets/views/light/Settings.PNG?raw=true"><img alt="Library" src="https://github.com/neoarz/StikJIT/blob/main/assets/views/dark/Settings.PNG?raw=true" width="200"></picture></p> | <p align="center"><picture><source media="(prefers-color-scheme: dark)" srcset="https://github.com/neoarz/StikJIT/blob/main/assets/views/dark/GetJIT.gif?raw=true"><source media="(prefers-color-scheme: light)" srcset="https://github.com/neoarz/StikJIT/blob/main/assets/views/light/GetJIT.gif?raw=true"><img alt="Signing" src="https://github.com/neoarz/StikJIT/blob/main/assets/views/dark/GetJIT.gif?raw=true" width="200"></picture></p> |
|:--:|:--:|:--:|:--:|
| **Home Screen** | **Apps List** | **Settings** | **JIT Under 10 Seconds** |
<h6 align="center">

  <a href="https://discord.gg/ZnNcrRT3M8">
    <img src="https://img.shields.io/badge/Discord-join%20us-7289DA?logo=discord&logoColor=white&style=for-the-badge&labelColor=23272A" />
  </a>
  <a href="https://github.com/0-Blu/StikJIT/blob/main/LICENSE">
    <img src="https://img.shields.io/github/license/0-Blu/StikJIT?label=License&color=5865F2&style=for-the-badge&labelColor=23272A" />
  </a>
  <a href="https://github.com/0-Blu/StikJIT/releases">
    <img src="https://img.shields.io/github/v/release/0-Blu/StikJIT?include_prereleases&label=Release&color=57F287&style=for-the-badge&labelColor=23272A" />
  </a>
  <a href="https://github.com/0-Blu/StikJIT/releases">
    <img src="https://img.shields.io/github/downloads/0-Blu/StikJIT/total?label=Downloads&color=ED4245&style=for-the-badge&labelColor=23272A" />
  </a>
  <a href="https://github.com/0-Blu/StikJIT/stargazers">
    <img src="https://img.shields.io/github/stars/0-Blu/StikJIT?label=Stars&color=FEE75C&style=for-the-badge&labelColor=23272A" />
  </a>
  <br />
</h6>

## Features  
- On-device Just-In-Time (JIT) compilation for supported apps via [`idevice`](https://github.com/jkcoxson/idevice).  
- Seamless integration with [`em_proxy`](https://github.com/SideStore/em_proxy).  
- Native UI for managing JIT-enabling.  
- No data collection—ensuring full privacy. 

## Building Instructions  

1. **Clone the repository:**  
   ```sh
   git clone https://github.com/0-Blu/StikJIT.git
   cd StikJIT
   ```

2. **Build using Makefile:**
   ```sh
   make package  # Build unsigned .ipa
   ```

3. **Updating:**
   ```sh
   git pull
   make clean  # Clean previous build
   make package  # Rebuild
   ```
> [!WARNING]
> The __Makefile__ build creates an unsigned .ipa in the `packages` directory. While this is useful for quick builds, please use Xcode for development and debugging. When submitting pull requests or reporting issues, ensure you've tested your changes thoroughly using Xcode.



## Contributing 
```sh
# Clone the repository
git clone https://github.com/0-Blu/StikJIT.git
cd StikJIT

# Open in Xcode
open StikJIT.xcodeproj
```

Then in Xcode:
- Connect your iOS device
- Select your device in Xcode
- Build and run the project (⌘R)

## License  
StikDebug is licensed under **AGPL-3.0**. See [`LICENSE`](LICENSE) for details.  
