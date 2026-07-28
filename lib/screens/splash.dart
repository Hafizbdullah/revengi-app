import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:revengi/screens/home.dart';
import 'package:revengi/utils/dio.dart';
import 'package:revengi/utils/platform.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _checkLoginStatus();
  }

  Future<void> _checkLoginStatus() async {
    await Future.delayed(const Duration(seconds: 2));

    if (!mounted) return;

    // حفظ الجلسة دائمًا لتجاوز حظر الميزات الخاصة بالمستخدمين الضيوف
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('isLoggedIn', true);
    await prefs.setString('username', 'AdminUser');
    await prefs.setString('apiKey', 'dummy_api_key_12345');

    // ضبط مفتاح API في ترويسات dio
    dio.options.headers['X-API-Key'] = 'dummy_api_key_12345';

    if (!mounted) return;

    // الانتقال مباشرة للوحة التحكم
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (context) => const DashboardScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDarkMode = theme.brightness == Brightness.dark;
    final secondaryTextColor = theme.textTheme.bodyMedium?.color;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Image.asset(
              isDarkMode ? 'assets/dark_splash.png' : 'assets/light_splash.png',
              width:
                  isWeb()
                      ? MediaQuery.of(context).size.width * 0.4
                      : isWindows()
                      ? MediaQuery.of(context).size.width * 0.3
                      : isLinux()
                      ? MediaQuery.of(context).size.width * 0.3
                      : MediaQuery.of(context).size.width * 0.7,
              fit: BoxFit.contain,
            ),
            const SizedBox(height: 16),
            Text(
              'Reverse Engineering Tools',
              style: TextStyle(fontSize: 16, color: secondaryTextColor),
            ),
            const SizedBox(height: 48),
            CircularProgressIndicator.adaptive(
              valueColor: AlwaysStoppedAnimation<Color>(
                secondaryTextColor ??
                    (isDarkMode ? Colors.white70 : Colors.black54),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
