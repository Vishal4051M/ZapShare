import 'package:zap_share/Screens/HttpFileShareScreen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_swiper_null_safety/flutter_swiper_null_safety.dart';
import 'package:smooth_page_indicator/smooth_page_indicator.dart';
import 'LocalScreen.dart';
import 'UploadScreen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int currentIndex = 0;
  bool isTapped = false;

  final List<String> labels = ["local", "global", "settings"];
  final List<IconData> icons = [
    Icons.phone_android,
    Icons.computer_rounded,
    Icons.public,
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text(
          "ZapShare",
          style: TextStyle(
            color: Colors.white,
            fontSize: 24,
            fontWeight: FontWeight.bold,
          ),
          textAlign: TextAlign.center,
        ),
      ),
      backgroundColor: Colors.black,
      body: Column(
        children: [
          Expanded(
            child: Swiper(
              itemBuilder: (BuildContext context, int index) {
                return Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    GestureDetector(
                      onTapDown: (_) => setState(() => isTapped = true),
                      onTapUp: (_) {
                        Future.delayed(Duration(milliseconds: 150), () {
                          setState(() => isTapped = false);
                          _navigateToScreen(index);
                        });
                      },
                      onTapCancel: () => setState(() => isTapped = false),
                      child: _animatedButton(index),
                    ),
                  ],
                );
              },
              itemCount: 3,
              loop: false,
              onIndexChanged: (index) {
                setState(() {
                  currentIndex = index;
                });
              },
            ),
          ),

      
          Padding(
            padding: const EdgeInsets.only(bottom: 30),
            child: AnimatedSmoothIndicator(
              activeIndex: currentIndex,
              count: 3,
              effect: WormEffect(
                activeDotColor: Colors.white,
                dotColor: Colors.grey,
                dotHeight: 10,
                dotWidth: 10,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _navigateToScreen(int index) {
    Widget targetScreen;
    if (index == 0) {
      targetScreen = LocalScreen();
    } else if (index == 1) {
      targetScreen = HttpFileShareScreen();
    } else {
      targetScreen = UploadScreen();
    }

    Navigator.push(
      context,
      PageRouteBuilder(
        transitionDuration: Duration(milliseconds: 200),
        pageBuilder: (context, animation, secondaryAnimation) => targetScreen,
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          var scaleTween = Tween<double>(begin: 0.8, end: 1.0)
              .chain(CurveTween(curve: Curves.easeInOut));
          return ScaleTransition(
            scale: animation.drive(scaleTween),
            child: child,
          );
        },
      ),
    );
  }

  Widget _animatedButton(int index) {
    return AnimatedContainer(
      duration: Duration(milliseconds: 150),
      height: isTapped ? 200 : 220,
      width: isTapped ? 200 : 220,
      decoration: BoxDecoration(
        color: Colors.yellow.shade300,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Color(0x80000000),
            blurRadius: isTapped ? 8.0 : 12.0,
            offset: Offset(0.0, 5.0),
          ),
        ],
      ),
      child: Center(
        child: Icon(
          icons[index],
          size: 90,
          color: Colors.black,
        ),
      ),
    );
  }
}