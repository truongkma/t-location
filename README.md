> [!CAUTION]
> **WARNING:** There are known critical issues with **iOS 26.4 Developer Beta 1**. The `lockdownd` service appears to be dropping connections, which interferes with how the device connects to itself (loopback/pairing issues) and prevents JIT from functioning. **DO NOT UPDATE** if you rely on StikDebug. These issues and possible fixes are currently being investigated.

<div align="center">
   <img width="217" height="217" src="/assets/StikJIT.png" alt="Logo">
</div>

<div align="center">
  <h1><b>StikDebug</b></h1>
  <p><i> An on-device debugger/JIT enabler for iOS versions 17.4+ powered by <a href="https://github.com/jkcoxson/idevice">idevice.</a> </i></p>
</div>

<h6 align="center">
  <a href="https://discord.gg/ZnNcrRT3M8">
    <img src="https://img.shields.io/badge/Discord-join%20us-7289DA?logo=discord&logoColor=white&style=for-the-badge&labelColor=23272A" />
  </a>
  <a href="https://github.com/StephenDev0/StikDebug/blob/main/LICENSE">
    <img src="https://img.shields.io/github/license/0-Blu/StikJIT?label=License&color=5865F2&style=for-the-badge&labelColor=23272A" />
  </a>
  <a href="https://github.com/StephenDev0/StikDebug/stargazers">
    <img src="https://img.shields.io/github/stars/0-Blu/StikJIT?label=Stars&color=FEE75C&style=for-the-badge&labelColor=23272A" />
  </a>
  <br />
</h6>

# Download

> [!WARNING]
> **Notice:** StikDebug is no longer available on the App Store. Please use the official download methods below.

<div align="center" style="display: flex; justify-content: center; align-items: center; gap: 16px; flex-wrap: wrap;">
   <a href="https://stikstore.app/altdirect/?url=https://stikdebug.xyz/index.json" target="_blank">
  <img src="https://github.com/stikstore/altdirect/blob/main/assets/png/AltSource_Blue.png" alt="Add AltSource" width="200">
   </a>
   <a href="https://github.com/StephenDev0/StikDebug/releases/download/2.3.7/StikDebug-2.3.7.ipa" target="_blank">
  <img src="https://github.com/stikstore/altdirect/blob/main/assets/png/Download_Blue.png" alt="Download .ipa" width="200">
   </a>
</div>

## Project Status
> [!NOTE]
> A major code cleanup and rewrite is currently underway on the [`semi-rewrite`](https://github.com/StephenDev0/StikDebug/tree/semi-rewrite) branch to improve stability and maintainability.

## Code Help
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/stephendev0/stikdebug)

## Features  
- On-device debugging/Just-In-Time (JIT) compilation for supported apps via [`idevice`](https://github.com/jkcoxson/idevice).  
- No special VPN/Network Extension entitlements required.  
- Native UI for managing debugging/JIT-enabling.  
- No data collection—ensuring full privacy. 

## License  
StikDebug is licensed under **AGPL-3.0**. See [`LICENSE`](LICENSE) for details.
