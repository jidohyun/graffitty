# Keystore

Runtime: Android. Emulator or physical device.

Report PASS, FAIL, or BLOCKED with evidence. This full procedure needs recorded LLM/manual execution. The separate entry-smoke and Keystore cases have automated ADB runners; they do not establish this case as passing.

The existing automated test uses a disposable package (`com.graffitty.auth_test`) and two application launches. It does not alter the user's client data.

```sh
mise run android:build
ANDROID_SERIAL=emulator-5554 mise exec -- python3 tests/android/test_android_credentials.py
```

1. Select the emulator/device explicitly. Ensure its ABI matches the APK and the build prerequisites are available.
2. Run the tool. It must report both save and retrieve-after-restart/delete assertions as PASS.
3. Treat export, install, launch, timeout, credential-provider, or deletion failures as FAIL/BLOCKED; a Mac Keychain test is not a substitute.
4. For a physical-device release check, repeat on the target phone. Emulator success validates the Android API path, not hardware-backed key security or every vendor's implementation.

The tool installs and removes only its dedicated test package. Never clear the real Graffitty client's application data for this test.
