import 'package:flutter/material.dart';

void main() {
  runApp(const TwinsApp());
}

class TwinsApp extends StatelessWidget {
  const TwinsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Twins',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0B1120),
        primaryColor: const Color(0xFF0284C7),
      ),
      home: const MainVideoFeedScreen(),
    );
  }
}

class MainVideoFeedScreen extends StatefulWidget {
  const MainVideoFeedScreen({super.key});

  @override
  State<MainVideoFeedScreen> createState() => _MainVideoFeedScreenState();
}

class _MainVideoFeedScreenState extends State<MainVideoFeedScreen> {
  final FixedExtentScrollController _wheelController = FixedExtentScrollController(initialItem: 2);
  
  final List<String> _categories = [
    'Trending',
    'Lookalikes',
    'Dancing',
    'Style',
    'Comedy',
    'Music',
    'Sports',
  ];

  @override
  void dispose() {
    _wheelController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // 1. Full Screen Video Background Placeholder
          Positioned.fill(
            child: Container(
              color: const Color(0xFF0F172A),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Icon(
                    Icons.play_circle_outline,
                    size: 80,
                    color: Colors.white.withValues(alpha: 0.2),
                  ),
                  const Positioned(
                    bottom: 180,
                    child: Text(
                      'Video Feed Active',
                      style: TextStyle(color: Colors.white30, fontSize: 16),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // 2. Main UI Layout
          SafeArea(
            child: Column(
              children: [
                // Top Header Section
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // TWINS Brand Logo
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(6),
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: LinearGradient(
                                colors: [Color(0xFF0284C7), Color(0xFF38BDF8)],
                              ),
                            ),
                            child: const Icon(Icons.people_alt, color: Colors.white, size: 20),
                          ),
                          const SizedBox(width: 8),
                          ShaderMask(
                            shaderCallback: (bounds) => const LinearGradient(
                              colors: [Colors.white, Color(0xFF38BDF8)],
                            ).createShader(bounds),
                            child: const Text(
                              'TWINS',
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 1.2,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ],
                      ),
                      // Search Action
                      IconButton(
                        icon: const Icon(Icons.search, color: Colors.white, size: 28),
                        onPressed: () {},
                      ),
                    ],
                  ),
                ),

                // Top Floating Cards (New Match & Celebrities)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 80% New Match Card
                      _buildMatchCard(
                        matchPercentage: '80%',
                        title: 'New Match',
                        flagEmoji: '🇧🇷',
                        isLocked: false,
                        height: 110,
                      ),
                      const SizedBox(width: 12),
                      // 94% Celebrities Locked Card
                      _buildMatchCard(
                        matchPercentage: '94%',
                        title: 'Celebrities',
                        flagEmoji: '',
                        isLocked: true,
                        height: 130,
                      ),
                    ],
                  ),
                ),

                const Spacer(),

                // Bottom Content Row (Captions + Right Action Column)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      // Left Column: Music Tag & Notebook Paper Caption
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Audio Track Pill
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.6),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(color: Colors.white24),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.music_note, color: Color(0xFF38BDF8), size: 16),
                                  SizedBox(width: 6),
                                  Text(
                                    'Original Sound - @roscoe',
                                    style: TextStyle(color: Colors.white, fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 12),
                            // Notebook Paper Caption Box
                            _buildRuledPaperCaption(),
                          ],
                        ),
                      ),

                      const SizedBox(width: 16),

                      // Right Column: Vertical Controls & Category Wheel
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Blue Plus / Upload Button
                          Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: const Color(0xFF0284C7),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFF0284C7).withValues(alpha: 0.5),
                                  blurRadius: 10,
                                  spreadRadius: 2,
                                ),
                              ],
                            ),
                            child: IconButton(
                              icon: const Icon(Icons.add, color: Colors.white, size: 28),
                              onPressed: () {},
                            ),
                          ),
                          const SizedBox(height: 20),

                          // 3D Vertical Category Scroll Wheel
                          SizedBox(
                            height: 120,
                            width: 70,
                            child: ListWheelScrollView.useDelegate(
                              controller: _wheelController,
                              itemExtent: 32,
                              perspective: 0.005,
                              diameterRatio: 1.2,
                              physics: const FixedExtentScrollPhysics(),
                              childDelegate: ListWheelChildBuilderDelegate(
                                childCount: _categories.length,
                                builder: (context, index) {
                                  return Container(
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: Colors.black.withValues(alpha: 0.46),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      _categories[index],
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                          const SizedBox(height: 20),

                          // Action Icons
                          _buildSideActionButton(Icons.favorite, '24.5K', Colors.red),
                          const SizedBox(height: 16),
                          _buildSideActionButton(Icons.comment, '1,024', Colors.white),
                          const SizedBox(height: 16),
                          
                          // Profile Avatar
                          Container(
                            padding: const EdgeInsets.all(2),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: const Color(0xFF38BDF8), width: 2),
                            ),
                            child: const CircleAvatar(
                              radius: 20,
                              backgroundColor: Color(0xFF1E293B),
                              child: Icon(Icons.person, color: Colors.white),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Floating Overlay Match Card Helper
  Widget _buildMatchCard({
    required String matchPercentage,
    required String title,
    required String flagEmoji,
    required bool isLocked,
    required double height,
  }) {
    return Container(
      width: 100,
      height: height,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isLocked
              ? [const Color(0xFF4C1D95), const Color(0xFF1E1B4B)]
              : [const Color(0xFF0F172A), const Color(0xFF334155)],
        ),
        border: Border.all(
          color: isLocked ? const Color(0xFFA855F7) : const Color(0xFF0284C7),
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: isLocked ? Colors.purple : const Color(0xFF0284C7),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  matchPercentage,
                  style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: Colors.white),
                ),
              ),
              if (flagEmoji.isNotEmpty) Text(flagEmoji, style: const TextStyle(fontSize: 12)),
            ],
          ),
          if (isLocked)
            const Center(
              child: Icon(Icons.lock, color: Colors.amber, size: 26),
            ),
          Text(
            title,
            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  // Side Bar Action Buttons
  Widget _buildSideActionButton(IconData icon, String label, Color iconColor) {
    return Column(
      children: [
        Icon(icon, color: iconColor, size: 30),
        const SizedBox(height: 4),
        Text(
          label,
          style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }

  // Notebook Paper Caption Widget
  Widget _buildRuledPaperCaption() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 8,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: CustomPaint(
        painter: RuledLinesPainter(),
        child: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '@roscoe',
              style: TextStyle(
                color: Color(0xFF1E3A8A),
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
            SizedBox(height: 6),
            Text(
              'Testing out the new TWINS layout screen UI in Flutter! 🚀',
              style: TextStyle(
                color: Color(0xFF1D4ED8),
                fontSize: 13,
                fontFamily: 'Serif',
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Custom Painter to draw horizontal paper lines
class RuledLinesPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFCBD5E1)
      ..strokeWidth = 0.8;

    double lineSpacing = 18.0;
    for (double y = lineSpacing; y < size.height; y += lineSpacing) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}