import 'dart:io';
import 'dart:ui';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:google_fonts/google_fonts.dart';

void main() {
  runApp(const TwinsApp());
}

// ---------------------------------------------------------------------------
// AUTH (account creation, Google sign-in, guest mode)
//
// Guests can watch the feed, but every other action (like, follow, message,
// repost, commenting, posting a video, unlocking celebrities) must call
// authController.requireAccount(context) first. If they're a guest it shows
// a sign-up prompt and blocks the action; if they're logged in it lets it
// through.
// ---------------------------------------------------------------------------
class AppUser {
  final String username;
  final String email;
  String avatarUrl;
  Uint8List? avatarBytes;
  int followers;
  int following;

  AppUser({
    required this.username,
    required this.email,
    this.avatarUrl = '',
    this.avatarBytes,
    this.followers = 0,
    this.following = 0,
  });
}

class AuthController extends ChangeNotifier {
  AppUser? currentUser;

  // Simple in-memory "database" of created accounts, keyed by email.
  final Map<String, String> _accounts = {};

  bool get isGuest => currentUser == null;

  /// Create an account with a username, email (gmail or any email) and
  /// password. Returns an error message, or null on success.
  String? signUp({
    required String username,
    required String email,
    required String password,
  }) {
    if (username.trim().isEmpty || email.trim().isEmpty || password.isEmpty) {
      return 'Please fill in all fields.';
    }
    if (_accounts.containsKey(email)) {
      return 'An account with that email already exists.';
    }
    _accounts[email] = password;
    currentUser = AppUser(username: username.trim(), email: email.trim());
    notifyListeners();
    return null;
  }

  String? signIn({required String email, required String password}) {
    if (_accounts[email] != password) {
      return 'Incorrect email or password.';
    }
    currentUser = AppUser(username: email.split('@').first, email: email);
    notifyListeners();
    return null;
  }

  /// Sign up / sign in by choosing a Google account.
  Future<String?> signInWithGoogle() async {
    try {
      final googleUser = await GoogleSignIn().signIn();
      if (googleUser == null) return 'Google sign-in cancelled.';
      currentUser = AppUser(
        username: googleUser.displayName ?? googleUser.email.split('@').first,
        email: googleUser.email,
        avatarUrl: googleUser.photoUrl ?? '',
      );
      notifyListeners();
      return null;
    } catch (e) {
      return 'Google sign-in failed: $e';
    }
  }

  void continueAsGuest() {
    currentUser = null;
    notifyListeners();
  }

  void signOut() {
    currentUser = null;
    notifyListeners();
  }

  /// Call before any restricted action. Returns true if allowed to proceed;
  /// otherwise shows a sign-up prompt and returns false.
  bool requireAccount(BuildContext context) {
    if (!isGuest) return true;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline, color: Colors.cyanAccent, size: 32),
            const SizedBox(height: 12),
            const Text(
              'Create an account to like, follow, message, repost and post your own videos.',
              style: TextStyle(color: Colors.white, fontSize: 15),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0284C7),
                ),
                onPressed: () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const SignUpScreen()),
                  );
                },
                child: const Text('Sign Up'),
              ),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const LoginScreen()),
                );
              },
              child: const Text(
                'I already have an account',
                style: TextStyle(color: Colors.white70),
              ),
            ),
          ],
        ),
      ),
    );
    return false;
  }
}

/// Single global auth instance used across the app.
final authController = AuthController();

// ---------------------------------------------------------------------------
// SIGN UP SCREEN
// ---------------------------------------------------------------------------
class SignUpScreen extends StatefulWidget {
  const SignUpScreen({super.key});

  @override
  State<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends State<SignUpScreen> {
  final _usernameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _loading = false;
  String? _error;

  void _submit() {
    setState(() {
      _error = authController.signUp(
        username: _usernameController.text,
        email: _emailController.text,
        password: _passwordController.text,
      );
    });
    if (_error == null && mounted) Navigator.pop(context);
  }

  Future<void> _googleSignIn() async {
    setState(() => _loading = true);
    final error = await authController.signInWithGoogle();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = error;
    });
    if (error == null) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B1120),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0B1120),
        title: const Text(
          'Create Account',
          style: TextStyle(color: Colors.white),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _usernameController,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Username',
                  labelStyle: TextStyle(color: Colors.white70),
                ),
              ),
              TextField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Gmail / Email',
                  labelStyle: TextStyle(color: Colors.white70),
                ),
              ),
              TextField(
                controller: _passwordController,
                obscureText: true,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Password',
                  labelStyle: TextStyle(color: Colors.white70),
                ),
              ),
              const SizedBox(height: 16),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: Colors.redAccent),
                  ),
                ),
              _loading
                  ? const Center(child: CircularProgressIndicator())
                  : Column(
                      children: [
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF0284C7),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          onPressed: _submit,
                          child: const Text('Sign Up'),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Colors.cyanAccent),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          onPressed: _googleSignIn,
                          icon: const Icon(
                            Icons.g_mobiledata,
                            color: Colors.white,
                            size: 26,
                          ),
                          label: const Text(
                            'Continue with Google',
                            style: TextStyle(color: Colors.white),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextButton(
                          onPressed: () => Navigator.pushReplacement(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const LoginScreen(),
                            ),
                          ),
                          child: const Text(
                            'Already have an account? Log in',
                            style: TextStyle(color: Colors.white54),
                          ),
                        ),
                      ],
                    ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// LOG IN SCREEN
// ---------------------------------------------------------------------------
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _loading = false;
  String? _error;

  void _submit() {
    setState(() {
      _error = authController.signIn(
        email: _emailController.text,
        password: _passwordController.text,
      );
    });
    if (_error == null && mounted) Navigator.pop(context);
  }

  Future<void> _googleSignIn() async {
    setState(() => _loading = true);
    final error = await authController.signInWithGoogle();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = error;
    });
    if (error == null) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B1120),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0B1120),
        title: const Text('Log In', style: TextStyle(color: Colors.white)),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Gmail / Email',
                  labelStyle: TextStyle(color: Colors.white70),
                ),
              ),
              TextField(
                controller: _passwordController,
                obscureText: true,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Password',
                  labelStyle: TextStyle(color: Colors.white70),
                ),
              ),
              const SizedBox(height: 16),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: Colors.redAccent),
                  ),
                ),
              _loading
                  ? const Center(child: CircularProgressIndicator())
                  : Column(
                      children: [
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF0284C7),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          onPressed: _submit,
                          child: const Text('Log In'),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Colors.cyanAccent),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          onPressed: _googleSignIn,
                          icon: const Icon(
                            Icons.g_mobiledata,
                            color: Colors.white,
                            size: 26,
                          ),
                          label: const Text(
                            'Continue with Google',
                            style: TextStyle(color: Colors.white),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextButton(
                          onPressed: () => Navigator.pushReplacement(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const SignUpScreen(),
                            ),
                          ),
                          child: const Text(
                            "Don't have an account? Sign up",
                            style: TextStyle(color: Colors.white54),
                          ),
                        ),
                      ],
                    ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// MESSAGE SCREEN (direct message with the creator of the video being watched)
// ---------------------------------------------------------------------------
class MessageScreen extends StatefulWidget {
  final VideoItem video;
  const MessageScreen({super.key, required this.video});

  @override
  State<MessageScreen> createState() => _MessageScreenState();
}

class _MessageScreenState extends State<MessageScreen> {
  final _controller = TextEditingController();

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    setState(() {
      widget.video.messages.add('me:$text');
      _controller.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final messages = widget.video.messages;
    return Scaffold(
      backgroundColor: const Color(0xFF0B1120),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0B1120),
        title: Text(
          widget.video.username,
          style: const TextStyle(color: Colors.white),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: messages.isEmpty
                ? const Center(
                    child: Text(
                      'Say hi 👋',
                      style: TextStyle(color: Colors.white38),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: messages.length,
                    itemBuilder: (context, i) {
                      final raw = messages[i];
                      final isMe = raw.startsWith('me:');
                      final text = raw.substring(raw.indexOf(':') + 1);
                      return Align(
                        alignment: isMe
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: isMe
                                ? const Color(0xFF0284C7)
                                : Colors.blueGrey.shade800,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Text(
                            text,
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        hintText: 'Message ${widget.video.username}...',
                        hintStyle: const TextStyle(color: Colors.white38),
                        filled: true,
                        fillColor: Colors.black26,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.send, color: Colors.cyanAccent),
                    onPressed: _send,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// APP ROOT
// ---------------------------------------------------------------------------
class TwinsApp extends StatelessWidget {
  const TwinsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Twins - Lookalike Network',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0B1120),
        primaryColor: const Color(0xFF0284C7),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF0284C7),
          secondary: Color(0xFF38BDF8),
          surface: Color(0xFF1E293B),
        ),
      ),
      home: const MainVideoFeedScreen(),
    );
  }
}

// ---------------------------------------------------------------------------
// DATA MODELS
// ---------------------------------------------------------------------------
class VideoItem {
  final String id;
  final String username;
  final String caption;
  final String musicTrack;
  final String category;
  int likes;
  int comments;
  bool likedByMe;

  // Account-level info for the creator of this video, shown when their
  // circular profile picture is tapped.
  final String creatorAvatarUrl;
  int followers;
  int following;
  int accountLikes;
  int reposts;
  int videoCount;
  bool isFollowedByMe;
  final List<String> messages;

  // The actual picked video - a local file path (Android/iOS/desktop) or
  // a blob: URL (web). Null for the built-in demo videos, which show a
  // placeholder instead since there's no real media file behind them.
  final String? mediaUrl;

  VideoItem({
    required this.id,
    required this.username,
    required this.caption,
    required this.musicTrack,
    required this.category,
    required this.likes,
    required this.comments,
    this.likedByMe = false,
    this.creatorAvatarUrl = '',
    this.followers = 0,
    this.following = 0,
    this.accountLikes = 0,
    this.reposts = 0,
    this.videoCount = 1,
    this.isFollowedByMe = false,
    List<String>? messages,
    this.mediaUrl,
  }) : messages = messages ?? [];
}

class MatchProfile {
  final String name;
  final String country;
  final int percentage;
  final bool isCelebrity;
  final bool locked;
  final String imageUrl;

  MatchProfile({
    required this.name,
    required this.country,
    required this.percentage,
    this.isCelebrity = false,
    this.locked = false,
    this.imageUrl = '',
  });
}

// ---------------------------------------------------------------------------
// SHARED VIDEO FEED STORE
//
// A single in-memory list of every video in the app, shared by the feed
// and every profile screen. When someone posts a video it's appended here
// and everything listening (the feed, "my uploads") updates immediately.
// This is temporary storage until a real backend/database is connected -
// videos reset when the app restarts.
// ---------------------------------------------------------------------------
class VideoFeedStore extends ChangeNotifier {
  final List<VideoItem> videos = [
    VideoItem(
      id: '1',
      username: '@alex_lookalike',
      caption: 'Found my 89% facial twin in Brazil! What do you think?',
      musicTrack: 'Original Sound - Alex & Twin',
      category: 'Dancing',
      likes: 12400,
      comments: 320,
      followers: 8900,
      following: 210,
      accountLikes: 152000,
      reposts: 640,
      videoCount: 14,
    ),
    VideoItem(
      id: '2',
      username: '@marcus_v',
      caption: 'Trying the new style trend with my community matches.',
      musicTrack: 'Trending Beat - Midnight Vibe',
      category: 'Style',
      likes: 45200,
      comments: 890,
      followers: 24100,
      following: 180,
      accountLikes: 610000,
      reposts: 2100,
      videoCount: 32,
    ),
    VideoItem(
      id: '3',
      username: '@david_twin_find',
      caption: 'Testing the twin-match algorithm live on stage!',
      musicTrack: 'Soundtrack - Twin Sync Vol 1',
      category: 'Fashion',
      likes: 9800,
      comments: 154,
      followers: 5300,
      following: 96,
      accountLikes: 88000,
      reposts: 310,
      videoCount: 8,
    ),
  ];

  void addVideo(VideoItem video) {
    videos.add(video);
    notifyListeners();
  }
}

final videoFeedStore = VideoFeedStore();

// ---------------------------------------------------------------------------
// MAIN FEED SCREEN
// ---------------------------------------------------------------------------
class MainVideoFeedScreen extends StatefulWidget {
  const MainVideoFeedScreen({super.key});

  @override
  State<MainVideoFeedScreen> createState() => _MainVideoFeedScreenState();
}

class _MainVideoFeedScreenState extends State<MainVideoFeedScreen> {
  final PageController _pageController = PageController();
  final FixedExtentScrollController _categoryWheelController =
      FixedExtentScrollController();

  // The feed now reads from the shared, app-wide video store so newly
  // posted videos appear here immediately.
  List<VideoItem> get _videos => videoFeedStore.videos;

  final List<String> _categories = [
    'Dancing',
    'Style',
    'Fashion',
    'Fitness',
    'Travel',
    'Comedy',
    'Acting',
  ];

  String _selectedCategory = 'Dancing';
  int _currentIndex = 0;

  VideoItem get _currentVideo => _videos[_currentIndex];

  final MatchProfile _newMatch = MatchProfile(
    name: 'Rafael M.',
    country: 'Brazil',
    percentage: 80,
    imageUrl: 'https://i.pravatar.cc/400?img=32',
  );

  final MatchProfile _celebMatch = MatchProfile(
    name: 'Locked Celebrity',
    country: 'USA',
    percentage: 94,
    isCelebrity: true,
    locked: true,
  );

  @override
  void initState() {
    super.initState();
    // Rebuild the feed whenever a new video is posted anywhere in the app.
    videoFeedStore.addListener(_onFeedChanged);
  }

  void _onFeedChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    videoFeedStore.removeListener(_onFeedChanged);
    _pageController.dispose();
    _categoryWheelController.dispose();
    super.dispose();
  }

  void _toggleLike(VideoItem video) {
    if (!authController.requireAccount(context)) return;
    setState(() {
      video.likedByMe = !video.likedByMe;
      video.likes += video.likedByMe ? 1 : -1;
    });
  }

  void _toggleFollow(VideoItem video) {
    if (!authController.requireAccount(context)) return;
    setState(() {
      video.isFollowedByMe = !video.isFollowedByMe;
      video.followers += video.isFollowedByMe ? 1 : -1;
    });
  }

  void _openMessageScreen(VideoItem video) {
    if (!authController.requireAccount(context)) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => MessageScreen(video: video)),
    );
  }

  // -------------------------------------------------------------------
  // CREATOR PROFILE SHEET (tap the round profile picture next to a video)
  // -------------------------------------------------------------------
  void _showCreatorProfileSheet(VideoItem video) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          return FractionallySizedBox(
            heightFactor: 0.8,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  CircleAvatar(
                    radius: 36,
                    backgroundColor: const Color(0xFF0284C7),
                    backgroundImage: video.creatorAvatarUrl.isNotEmpty
                        ? NetworkImage(video.creatorAvatarUrl)
                        : null,
                    child: video.creatorAvatarUrl.isEmpty
                        ? const Icon(
                            Icons.person,
                            color: Colors.white,
                            size: 32,
                          )
                        : null,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    video.username,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _profileStat('Following', video.following),
                      _profileStat('Followers', video.followers),
                      _profileStat('Likes', video.accountLikes),
                      _profileStat('Reposts', video.reposts),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: video.isFollowedByMe
                              ? Colors.blueGrey.shade700
                              : const Color(0xFF0284C7),
                        ),
                        onPressed: () {
                          if (!authController.requireAccount(context)) return;
                          setState(() {
                            video.isFollowedByMe = !video.isFollowedByMe;
                            video.followers += video.isFollowedByMe ? 1 : -1;
                          });
                          setSheetState(() {});
                        },
                        child: Text(
                          video.isFollowedByMe ? 'Following' : 'Follow',
                        ),
                      ),
                      const SizedBox(width: 10),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Colors.cyanAccent),
                        ),
                        onPressed: () {
                          Navigator.pop(sheetContext);
                          _openMessageScreen(video);
                        },
                        icon: const Icon(
                          Icons.mail,
                          color: Colors.white,
                          size: 18,
                        ),
                        label: const Text(
                          'Message',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: GridView.builder(
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            crossAxisSpacing: 3,
                            mainAxisSpacing: 3,
                          ),
                      itemCount: video.videoCount,
                      itemBuilder: (context, i) => Container(
                        color: Colors.blueGrey.shade900,
                        alignment: Alignment.center,
                        child: video.creatorAvatarUrl.isNotEmpty
                            ? Image.network(
                                video.creatorAvatarUrl,
                                fit: BoxFit.cover,
                              )
                            : const Icon(Icons.videocam, color: Colors.white24),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _profileStat(String label, int value) {
    return Column(
      children: [
        Text(
          '$value',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(
          label,
          style: const TextStyle(color: Colors.white60, fontSize: 12),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Vertical scrolling video feed
          PageView.builder(
            controller: _pageController,
            scrollDirection: Axis.vertical,
            itemCount: _videos.length,
            onPageChanged: (index) {
              setState(() => _currentIndex = index);
            },
            itemBuilder: (context, index) {
              final video = _videos[index];
              return _buildVideoPage(video);
            },
          ),

          // Top bar: logo/title + match boxes + search
          SafeArea(
            child: Column(
              children: [
                _buildTopBar(),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildNewMatchBox(),
                      const SizedBox(width: 10),
                      _buildCelebrityBox(),
                      const SizedBox(width: 10),
                      _buildCreatorAvatarBox(_currentVideo),
                      const SizedBox(width: 10),
                      _buildMessageBox(_currentVideo),
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

  // -------------------------------------------------------------------
  // TOP BAR: Logo + Title + Search
  // -------------------------------------------------------------------
  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const SizedBox(width: 40), // balance for centering
          Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [Color(0xFF0284C7), Color(0xFF38BDF8)],
                  ),
                ),
                child: const Icon(
                  Icons.people_alt_rounded,
                  color: Colors.white,
                  size: 18,
                ),
              ),
              const SizedBox(width: 6),
              const Text(
                'Twins',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 20,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.search, color: Colors.white, size: 26),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SearchScreen()),
              );
            },
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------
  // NEW MATCH BOX
  // -------------------------------------------------------------------
  Widget _buildNewMatchBox() {
    return GestureDetector(
      onTap: () => _showMatchDetail(_newMatch),
      child: Container(
        width: 100,
        height: 110,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF38BDF8), width: 1.5),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                child: _newMatch.imageUrl.isNotEmpty
                    ? Image.network(
                        _newMatch.imageUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) =>
                            Container(color: Colors.blueGrey.shade700),
                      )
                    : Container(color: Colors.blueGrey.shade700),
              ),
              Container(color: Colors.black.withValues(alpha: 0.35)),
              const Center(
                child: Icon(
                  Icons.remove_red_eye,
                  color: Colors.white70,
                  size: 22,
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(6.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '${_newMatch.percentage}% Match',
                        style: const TextStyle(
                          color: Colors.cyanAccent,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'New Match',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 11,
                          ),
                        ),
                        Row(
                          children: [
                            const Icon(
                              Icons.location_on,
                              color: Colors.redAccent,
                              size: 10,
                            ),
                            const SizedBox(width: 2),
                            Text(
                              _newMatch.country,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 9,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------
  // CELEBRITY BOX (paywall)
  // -------------------------------------------------------------------
  Widget _buildCelebrityBox() {
    return GestureDetector(
      onTap: _showCelebrityPaywall,
      child: Container(
        width: 108,
        height: 130,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Colors.purple.shade900, Colors.indigo.shade900],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.amber.shade400, width: 1.5),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                child: Container(color: Colors.purple.shade700),
              ),
              Container(color: Colors.black.withValues(alpha: 0.5)),
              Padding(
                padding: const EdgeInsets.all(6.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.amber,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            '${_celebMatch.percentage}% Celeb',
                            style: const TextStyle(
                              color: Colors.black,
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const Icon(
                          Icons.lock,
                          color: Colors.amberAccent,
                          size: 14,
                        ),
                        const SizedBox(width: 2),
                        const Icon(
                          Icons.verified,
                          color: Colors.blueAccent,
                          size: 14,
                        ),
                      ],
                    ),
                    const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Celebrities',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        ),
                        Text(
                          'Unlock Twin',
                          style: TextStyle(color: Colors.white70, fontSize: 9),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------
  // CREATOR PROFILE AVATAR BOX (round pic of the person whose video is
  // currently playing - sits in the same row as new match / celebrities)
  // -------------------------------------------------------------------
  Widget _buildCreatorAvatarBox(VideoItem video) {
    return GestureDetector(
      onTap: () => _showCreatorProfileSheet(video),
      child: SizedBox(
        width: 64,
        height: 110,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 26,
              backgroundColor: const Color(0xFF0284C7),
              backgroundImage: video.creatorAvatarUrl.isNotEmpty
                  ? NetworkImage(video.creatorAvatarUrl)
                  : null,
              child: video.creatorAvatarUrl.isEmpty
                  ? const Icon(Icons.person, color: Colors.white, size: 26)
                  : null,
            ),
            const SizedBox(height: 4),
            Text(
              video.username,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------------
  // MESSAGE BOX (message the person whose video is currently playing)
  // -------------------------------------------------------------------
  Widget _buildMessageBox(VideoItem video) {
    return GestureDetector(
      onTap: () => _openMessageScreen(video),
      child: Container(
        width: 64,
        height: 110,
        alignment: Alignment.topCenter,
        padding: const EdgeInsets.only(top: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.cyan.shade600, width: 1.5),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF0284C7).withValues(alpha: 0.25),
              ),
              child: const Icon(Icons.mail, color: Colors.cyanAccent, size: 22),
            ),
            const SizedBox(height: 4),
            const Text(
              'Message',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------------
  // SINGLE VIDEO PAGE
  // -------------------------------------------------------------------
  Widget _buildVideoPage(VideoItem video) {
    return Container(
      color: const Color(0xFF0B1120),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Real playback for posted videos, placeholder for demo videos
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Colors.blueGrey.shade900,
                  Colors.blueGrey.shade800,
                  Colors.black,
                ],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
            child: video.mediaUrl != null
                ? _FeedVideoPlayer(mediaUrl: video.mediaUrl!)
                : const Center(
                    child: Icon(
                      Icons.play_circle_outline,
                      size: 80,
                      color: Colors.white30,
                    ),
                  ),
          ),

          // Music / sound pill - bottom left
          Positioned(
            left: 16,
            bottom: 150,
            child: GestureDetector(
              onTap: () => _showMusicSheet(video.musicTrack),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.black45,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.cyan.shade600),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.music_note,
                      color: Colors.cyanAccent,
                      size: 20,
                    ),
                    const SizedBox(width: 6),
                    SizedBox(
                      width: 140,
                      child: Text(
                        video.musicTrack,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Ruled-paper handwritten caption - bottom
          Positioned(
            left: 16,
            right: 80,
            bottom: 90,
            child: _buildRuledPaperCaption(video),
          ),

          // Home button - lower left corner
          Positioned(
            left: 16,
            bottom: 20,
            child: GestureDetector(
              onTap: () {
                _pageController.animateToPage(
                  0,
                  duration: const Duration(milliseconds: 400),
                  curve: Curves.easeInOut,
                );
              },
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.black45,
                  border: Border.all(color: Colors.cyan.shade600),
                ),
                child: const Icon(Icons.home, color: Colors.white, size: 24),
              ),
            ),
          ),

          // Share button - lower right corner
          Positioned(
            right: 16,
            bottom: 20,
            child: GestureDetector(
              onTap: () {
                Share.share(
                  'Check out ${video.username} on Twins! "${video.caption}"',
                );
              },
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.black45,
                  border: Border.all(color: Colors.cyan.shade600),
                ),
                child: const Icon(Icons.share, color: Colors.white, size: 24),
              ),
            ),
          ),

          // Right side action rail
          Positioned(
            right: 12,
            bottom: 100,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  onTap: () {
                    if (!authController.requireAccount(context)) return;
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const UploadScreen()),
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFF0284C7),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.cyan.withValues(alpha: 0.5),
                          blurRadius: 10,
                        ),
                      ],
                    ),
                    child: const Icon(Icons.add, color: Colors.white, size: 28),
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  height: 150,
                  width: 70,
                  child: ListWheelScrollView.useDelegate(
                    controller: _categoryWheelController,
                    itemExtent: 36,
                    perspective: 0.006,
                    diameterRatio: 1.2,
                    physics: const FixedExtentScrollPhysics(),
                    onSelectedItemChanged: (index) {
                      setState(() {
                        _selectedCategory = _categories[index];
                      });
                    },
                    childDelegate: ListWheelChildBuilderDelegate(
                      childCount: _categories.length,
                      builder: (context, catIndex) {
                        final isSelected =
                            _categories[catIndex] == _selectedCategory;
                        return Container(
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: isSelected
                                ? Colors.cyan.withValues(alpha: 0.3)
                                : Colors.black26,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: isSelected
                                  ? Colors.cyan
                                  : Colors.transparent,
                            ),
                          ),
                          child: Text(
                            _categories[catIndex],
                            style: TextStyle(
                              color: isSelected
                                  ? Colors.cyanAccent
                                  : Colors.white60,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                IconButton(
                  icon: Icon(
                    video.likedByMe ? Icons.favorite : Icons.favorite_border,
                    color: Colors.redAccent,
                    size: 32,
                  ),
                  onPressed: () => _toggleLike(video),
                ),
                Text(
                  '${video.likes}',
                  style: const TextStyle(color: Colors.white, fontSize: 11),
                ),
                const SizedBox(height: 12),
                IconButton(
                  icon: const Icon(
                    Icons.chat_bubble_outline,
                    color: Colors.white,
                    size: 30,
                  ),
                  onPressed: () => _showCommentsSheet(video),
                ),
                Text(
                  '${video.comments}',
                  style: const TextStyle(color: Colors.white, fontSize: 11),
                ),
                const SizedBox(height: 12),
                GestureDetector(
                  onTap: () {
                    if (!authController.requireAccount(context)) return;
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ProfileScreen(
                          username: authController.currentUser!.username,
                        ),
                      ),
                    );
                  },
                  child: CircleAvatar(
                    radius: 20,
                    backgroundColor: const Color(0xFF0284C7),
                    child: Text(
                      authController.isGuest
                          ? 'You'
                          : authController.currentUser!.username
                                .substring(0, 1)
                                .toUpperCase(),
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------
  // RULED PAPER / HANDWRITTEN CAPTION
  // -------------------------------------------------------------------
  Widget _buildRuledPaperCaption(VideoItem video) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: const Color(0xFFFDF6E3).withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(6),
        border: Border(left: BorderSide(color: Colors.red.shade300, width: 2)),
      ),
      child: CustomPaint(
        painter: _RuledLinePainter(),
        child: Padding(
          padding: const EdgeInsets.only(left: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                video.username,
                style: GoogleFonts.caveat(
                  color: const Color(0xFF0284C7),
                  fontWeight: FontWeight.bold,
                  fontSize: 20,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                video.caption,
                style: GoogleFonts.caveat(
                  color: const Color(0xFF1E293B),
                  fontSize: 19,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------
  // MATCH DETAIL / COMMUNITY MODAL
  // -------------------------------------------------------------------
  void _showMatchDetail(MatchProfile match) {
    bool revealed = false;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setRevealState) {
          return Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: GestureDetector(
                    onTap: () => setRevealState(() => revealed = true),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        ClipOval(
                          child: SizedBox(
                            width: 90,
                            height: 90,
                            child: match.imageUrl.isEmpty
                                ? Container(color: Colors.blueGrey.shade700)
                                : revealed
                                ? Image.network(
                                    match.imageUrl,
                                    fit: BoxFit.cover,
                                  )
                                : ImageFiltered(
                                    imageFilter: ImageFilter.blur(
                                      sigmaX: 14,
                                      sigmaY: 14,
                                    ),
                                    child: Image.network(
                                      match.imageUrl,
                                      fit: BoxFit.cover,
                                    ),
                                  ),
                          ),
                        ),
                        if (!revealed)
                          const Icon(
                            Icons.remove_red_eye,
                            color: Colors.white,
                            size: 26,
                          ),
                      ],
                    ),
                  ),
                ),
                if (!revealed)
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Center(
                      child: Text(
                        'Tap the photo to reveal',
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                    ),
                  ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          match.name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Row(
                          children: [
                            const Icon(
                              Icons.location_on,
                              color: Colors.redAccent,
                              size: 14,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              match.country,
                              style: const TextStyle(color: Colors.white70),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const Spacer(),
                    Text(
                      '${match.percentage}%',
                      style: const TextStyle(
                        color: Colors.cyanAccent,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                const Text(
                  'You and this person share strong facial similarity. Join their lookalike community or start your own with everyone who matches you.',
                  style: TextStyle(color: Colors.white70, height: 1.4),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF0284C7),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        onPressed: () {
                          Navigator.pop(context);
                          if (!authController.requireAccount(context)) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Joined the lookalike community!'),
                            ),
                          );
                        },
                        child: const Text('Join Community'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Colors.cyanAccent),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        onPressed: () {
                          Navigator.pop(context);
                          if (!authController.requireAccount(context)) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Community created! Invite others.',
                              ),
                            ),
                          );
                        },
                        child: const Text(
                          'Create Community',
                          style: TextStyle(color: Colors.cyanAccent),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // -------------------------------------------------------------------
  // CELEBRITY PAYWALL
  //
  // Browsing this box is open to everyone. To actually unlock celebrity
  // matches you must pay - and if you're still a guest, this same sheet
  // collects your account details first, styled to match the celebrity
  // box (purple/amber, blue verified tick, lock icon).
  // -------------------------------------------------------------------
  void _showCelebrityPaywall() {
    final usernameController = TextEditingController();
    final emailController = TextEditingController();
    final passwordController = TextEditingController();
    String? error;
    bool submitting = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          Future<void> unlock() async {
            if (authController.isGuest) {
              if (usernameController.text.trim().isEmpty ||
                  emailController.text.trim().isEmpty ||
                  passwordController.text.isEmpty) {
                setSheetState(() => error = 'Fill in all fields to continue.');
                return;
              }
              setSheetState(() {
                submitting = true;
                error = null;
              });
              final signUpError = authController.signUp(
                username: usernameController.text,
                email: emailController.text,
                password: passwordController.text,
              );
              if (signUpError != null) {
                setSheetState(() {
                  submitting = false;
                  error = signUpError;
                });
                return;
              }
            }
            if (!sheetContext.mounted) return;
            Navigator.pop(sheetContext);
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Connect a payment provider (Stripe/RevenueCat) here to finish unlocking celebrities.',
                ),
              ),
            );
          }

          Future<void> unlockWithGoogle() async {
            setSheetState(() {
              submitting = true;
              error = null;
            });
            final googleError = await authController.signInWithGoogle();
            setSheetState(() => submitting = false);
            if (googleError != null) {
              setSheetState(() => error = googleError);
              return;
            }
            if (!sheetContext.mounted) return;
            Navigator.pop(sheetContext);
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Connect a payment provider (Stripe/RevenueCat) here to finish unlocking celebrities.',
                ),
              ),
            );
          }

          return Container(
            padding: EdgeInsets.only(
              left: 20,
              right: 20,
              top: 20,
              bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 20,
            ),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Colors.purple.shade900, Colors.indigo.shade900],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(20),
              ),
              border: Border.all(color: Colors.amber.shade400, width: 1.5),
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: const [
                      Icon(Icons.lock, color: Colors.amber),
                      SizedBox(width: 6),
                      Icon(Icons.verified, color: Colors.blueAccent, size: 20),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Unlock Celebrity Matches',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'See which celebrities you resemble the most for \$4.99/month.',
                    style: TextStyle(color: Colors.white70),
                  ),
                  if (authController.isGuest) ...[
                    const SizedBox(height: 16),
                    const Text(
                      'Create your account to continue',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: usernameController,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: 'Username',
                        labelStyle: TextStyle(color: Colors.white70),
                      ),
                    ),
                    TextField(
                      controller: emailController,
                      keyboardType: TextInputType.emailAddress,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: 'Gmail / Email',
                        labelStyle: TextStyle(color: Colors.white70),
                      ),
                    ),
                    TextField(
                      controller: passwordController,
                      obscureText: true,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: 'Password',
                        labelStyle: TextStyle(color: Colors.white70),
                      ),
                    ),
                  ],
                  if (error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      error!,
                      style: const TextStyle(color: Colors.redAccent),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      TextButton(
                        onPressed: submitting
                            ? null
                            : () => Navigator.pop(sheetContext),
                        child: const Text(
                          'Not now',
                          style: TextStyle(color: Colors.white54),
                        ),
                      ),
                      const Spacer(),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.amber,
                        ),
                        onPressed: submitting ? null : unlock,
                        child: submitting
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.black,
                                ),
                              )
                            : const Text(
                                'Unlock - \$4.99',
                                style: TextStyle(color: Colors.black),
                              ),
                      ),
                    ],
                  ),
                  if (authController.isGuest) ...[
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Colors.cyanAccent),
                        ),
                        onPressed: submitting ? null : unlockWithGoogle,
                        icon: const Icon(
                          Icons.g_mobiledata,
                          color: Colors.white,
                          size: 24,
                        ),
                        label: const Text(
                          'Continue with Google & pay',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // -------------------------------------------------------------------
  // MUSIC SHEET
  // -------------------------------------------------------------------
  void _showMusicSheet(String track) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.music_note, color: Colors.cyanAccent, size: 40),
            const SizedBox(height: 10),
            Text(
              track,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0284C7),
                ),
                onPressed: () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const UploadScreen()),
                  );
                },
                child: const Text('Use This Sound'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------------
  // COMMENTS SHEET
  // -------------------------------------------------------------------
  void _showCommentsSheet(VideoItem video) {
    final commentController = TextEditingController();
    final localComments = <String>[
      'This is wild, you two could be brothers 😂',
      'The resemblance is unreal',
      'Twins app never disappoints',
    ];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
                left: 16,
                right: 16,
                top: 16,
              ),
              child: SizedBox(
                height: 420,
                child: Column(
                  children: [
                    Text(
                      '${localComments.length} Comments',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Divider(color: Colors.white24),
                    Expanded(
                      child: ListView.builder(
                        itemCount: localComments.length,
                        itemBuilder: (context, i) => ListTile(
                          leading: const CircleAvatar(
                            backgroundColor: Colors.blueGrey,
                            child: Icon(Icons.person, size: 18),
                          ),
                          title: Text(
                            localComments[i],
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: commentController,
                            style: const TextStyle(color: Colors.white),
                            decoration: InputDecoration(
                              hintText: 'Add a comment...',
                              hintStyle: const TextStyle(color: Colors.white38),
                              filled: true,
                              fillColor: Colors.black26,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 14,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(24),
                                borderSide: BorderSide.none,
                              ),
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(
                            Icons.send,
                            color: Colors.cyanAccent,
                          ),
                          onPressed: () {
                            if (commentController.text.trim().isEmpty) return;
                            if (!authController.requireAccount(context)) return;
                            setModalState(() {
                              localComments.add(commentController.text.trim());
                            });
                            setState(() {
                              video.comments++;
                            });
                            commentController.clear();
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// RULED LINE PAINTER (notebook-paper look behind the caption)
// ---------------------------------------------------------------------------
class _RuledLinePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.blue.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    for (double y = 22; y < size.height; y += 22) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ---------------------------------------------------------------------------
// FEED VIDEO PLAYER - plays back a video someone actually posted
// ---------------------------------------------------------------------------
class _FeedVideoPlayer extends StatefulWidget {
  final String mediaUrl;
  const _FeedVideoPlayer({required this.mediaUrl});

  @override
  State<_FeedVideoPlayer> createState() => _FeedVideoPlayerState();
}

class _FeedVideoPlayerState extends State<_FeedVideoPlayer> {
  VideoPlayerController? _controller;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final controller = kIsWeb
          ? VideoPlayerController.networkUrl(Uri.parse(widget.mediaUrl))
          : VideoPlayerController.file(File(widget.mediaUrl));
      await controller.initialize();
      controller.setLooping(true);
      controller.play();
      if (!mounted) return;
      setState(() => _controller = controller);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return const Center(
        child: Icon(Icons.error_outline, size: 60, color: Colors.white30),
      );
    }
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.cyanAccent),
      );
    }
    return GestureDetector(
      onTap: () {
        setState(() {
          controller.value.isPlaying ? controller.pause() : controller.play();
        });
      },
      child: ClipRect(
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: controller.value.size.width,
            height: controller.value.size.height,
            child: VideoPlayer(controller),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// SEARCH SCREEN
// ---------------------------------------------------------------------------
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final List<String> _allUsers = [
    '@alex_lookalike',
    '@marcus_v',
    '@david_twin_find',
    '@sofia_matches',
    '@twin_hunter_23',
  ];
  List<String> _results = [];

  void _search(String query) {
    setState(() {
      _results = query.isEmpty
          ? []
          : _allUsers
                .where((u) => u.toLowerCase().contains(query.toLowerCase()))
                .toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B1120),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0B1120),
        title: TextField(
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          onChanged: _search,
          decoration: const InputDecoration(
            hintText: 'Search profiles...',
            hintStyle: TextStyle(color: Colors.white38),
            border: InputBorder.none,
          ),
        ),
      ),
      body: _results.isEmpty
          ? const Center(
              child: Text(
                'Search for a profile',
                style: TextStyle(color: Colors.white38),
              ),
            )
          : ListView.builder(
              itemCount: _results.length,
              itemBuilder: (context, i) => ListTile(
                leading: const CircleAvatar(
                  backgroundColor: Colors.blueGrey,
                  child: Icon(Icons.person),
                ),
                title: Text(
                  _results[i],
                  style: const TextStyle(color: Colors.white),
                ),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ProfileScreen(username: _results[i]),
                    ),
                  );
                },
              ),
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// PROFILE SCREEN (uploaded videos, photo posts, saved favorites)
// ---------------------------------------------------------------------------
class ProfileScreen extends StatefulWidget {
  final String username;
  const ProfileScreen({super.key, this.username = 'You'});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  bool _uploadingAvatar = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    // Rebuild when the avatar/follow counts change or a new video posts.
    authController.addListener(_onChanged);
    videoFeedStore.addListener(_onChanged);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    authController.removeListener(_onChanged);
    videoFeedStore.removeListener(_onChanged);
    _tabController.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------
  // AVATAR UPLOAD
  //
  // Reads the picked image as bytes via XFile.readAsBytes(), which works
  // safely on web (unlike dart:io's File, which does not), Android, iOS
  // and desktop alike. Displayed with Image.memory.
  // -------------------------------------------------------------------
  Future<void> _pickAvatar() async {
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 800,
        imageQuality: 85,
      );
      if (picked == null) return; // cancelled
      setState(() => _uploadingAvatar = true);
      final bytes = await picked.readAsBytes();
      if (!mounted) return;
      authController.currentUser?.avatarBytes = bytes;
      authController.notifyListeners();
      setState(() => _uploadingAvatar = false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _uploadingAvatar = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not update profile picture: $e')),
      );
    }
  }

  Widget _statColumn(String label, int value) {
    return Column(
      children: [
        Text(
          '$value',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
        Text(
          label,
          style: const TextStyle(color: Colors.white60, fontSize: 12),
        ),
      ],
    );
  }

  Widget _grid(IconData icon, int count) {
    return count == 0
        ? Center(
            child: Text(
              'Nothing here yet',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.4)),
            ),
          )
        : GridView.builder(
            padding: const EdgeInsets.all(4),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 4,
              mainAxisSpacing: 4,
            ),
            itemCount: count,
            itemBuilder: (context, i) => Container(
              color: Colors.blueGrey.shade900,
              child: Icon(icon, color: Colors.white24),
            ),
          );
  }

  @override
  Widget build(BuildContext context) {
    final me = authController.currentUser;
    final myHandle = me == null ? '' : '@${me.username}';
    final myVideos = videoFeedStore.videos
        .where((v) => v.username == myHandle)
        .toList();
    final totalLikes = myVideos.fold<int>(0, (sum, v) => sum + v.likes);

    return Scaffold(
      backgroundColor: const Color(0xFF0B1120),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0B1120),
        title: Text(
          widget.username,
          style: const TextStyle(color: Colors.white),
        ),
        actions: [
          if (!authController.isGuest &&
              widget.username == authController.currentUser!.username)
            IconButton(
              icon: const Icon(Icons.logout, color: Colors.white70),
              tooltip: 'Sign out',
              onPressed: () {
                authController.signOut();
                Navigator.pop(context);
              },
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: GestureDetector(
              onTap: _uploadingAvatar ? null : _pickAvatar,
              child: Stack(
                alignment: Alignment.bottomRight,
                children: [
                  CircleAvatar(
                    radius: 40,
                    backgroundColor: const Color(0xFF0284C7),
                    backgroundImage: me?.avatarBytes != null
                        ? MemoryImage(me!.avatarBytes!)
                        : null,
                    child: _uploadingAvatar
                        ? const CircularProgressIndicator(color: Colors.white)
                        : (me?.avatarBytes == null
                              ? const Icon(
                                  Icons.person,
                                  size: 40,
                                  color: Colors.white,
                                )
                              : null),
                  ),
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(
                      color: Colors.cyanAccent,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.camera_alt,
                      size: 14,
                      color: Colors.black,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _statColumn('Following', me?.following ?? 0),
              _statColumn('Followers', me?.followers ?? 0),
              _statColumn('Likes', totalLikes),
            ],
          ),
          const SizedBox(height: 12),
          TabBar(
            controller: _tabController,
            indicatorColor: Colors.cyanAccent,
            tabs: const [
              Tab(icon: Icon(Icons.grid_on), text: 'Uploads'),
              Tab(icon: Icon(Icons.photo_camera_back), text: 'Photos'),
              Tab(icon: Icon(Icons.bookmark), text: 'Saved'),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _grid(Icons.videocam, myVideos.length),
                _grid(Icons.image, 0),
                _grid(Icons.favorite, 0),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// UPLOAD / EDIT SCREEN  (pick a real video from gallery or record one)
// ---------------------------------------------------------------------------
class UploadScreen extends StatefulWidget {
  const UploadScreen({super.key});

  @override
  State<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends State<UploadScreen> {
  final _captionController = TextEditingController();
  double _brightness = 0.5;
  double _speed = 1.0;
  String _filter = 'None';

  final List<String> _filters = ['None', 'Warm', 'Cool', 'B&W', 'Vivid'];

  XFile? _pickedFile;
  VideoPlayerController? _videoController;
  bool _isLoadingVideo = false;
  String? _pickError;
  String? _selectedMusicName;

  @override
  void dispose() {
    _videoController?.dispose();
    _captionController.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------
  // PICK A VIDEO FROM GALLERY OR RECORD A NEW ONE
  //
  // dart:io's File and VideoPlayerController.file() only work on
  // Android/iOS/desktop - NOT on Flutter web. On web the picked file
  // only exists as a blob: URL, so we must use
  // VideoPlayerController.networkUrl() there instead. Everything is
  // wrapped in try/catch/finally so the loading spinner can never get
  // stuck forever if something goes wrong.
  // -------------------------------------------------------------------
  Future<void> _pickVideo(ImageSource source) async {
    final picker = ImagePicker();
    XFile? file;
    try {
      file = await picker.pickVideo(
        source: source,
        maxDuration: const Duration(minutes: 3),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _pickError = 'Could not open picker: $e');
      return;
    }

    if (file == null) return; // user cancelled

    if (!mounted) return;
    setState(() {
      _isLoadingVideo = true;
      _pickError = null;
    });

    try {
      // Dispose any previous preview before loading a new one
      await _videoController?.dispose();

      final controller = kIsWeb
          ? VideoPlayerController.networkUrl(Uri.parse(file.path))
          : VideoPlayerController.file(File(file.path));

      await controller.initialize().timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw Exception('Video took too long to load.'),
      );
      controller.setLooping(true);
      controller.play();

      if (!mounted) return;
      setState(() {
        _pickedFile = file;
        _videoController = controller;
        _isLoadingVideo = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoadingVideo = false;
        _pickError = 'Could not load that video: $e';
      });
    }
  }

  void _showSourcePicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(
                Icons.video_library,
                color: Colors.cyanAccent,
              ),
              title: const Text(
                'Choose from gallery',
                style: TextStyle(color: Colors.white),
              ),
              onTap: () {
                Navigator.pop(context);
                _pickVideo(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: const Icon(Icons.videocam, color: Colors.cyanAccent),
              title: const Text(
                'Record a new video',
                style: TextStyle(color: Colors.white),
              ),
              onTap: () {
                Navigator.pop(context);
                _pickVideo(ImageSource.camera);
              },
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------------
  // PICK MUSIC FROM PHONE (swap the original sound for a chosen audio file)
  // -------------------------------------------------------------------
  Future<void> _pickMusic() async {
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.audio);
      final picked = result?.files.single;
      if (picked == null) return; // cancelled
      if (!mounted) return;
      setState(() => _selectedMusicName = picked.name);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open music picker: $e')),
      );
    }
  }

  // -------------------------------------------------------------------
  // PREVIEW AREA
  // -------------------------------------------------------------------
  Widget _buildPreviewArea() {
    if (_isLoadingVideo) {
      return Container(
        height: 220,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.blueGrey.shade900,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Colors.cyanAccent),
            SizedBox(height: 12),
            Text('Loading video...', style: TextStyle(color: Colors.white54)),
          ],
        ),
      );
    }

    if (_videoController != null && _videoController!.value.isInitialized) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: GestureDetector(
          onTap: () {
            setState(() {
              _videoController!.value.isPlaying
                  ? _videoController!.pause()
                  : _videoController!.play();
            });
          },
          child: AspectRatio(
            aspectRatio: _videoController!.value.aspectRatio,
            child: Stack(
              alignment: Alignment.center,
              children: [
                VideoPlayer(_videoController!),
                if (!_videoController!.value.isPlaying)
                  const Icon(Icons.play_arrow, size: 60, color: Colors.white70),
              ],
            ),
          ),
        ),
      );
    }

    // Nothing picked yet
    return GestureDetector(
      onTap: _showSourcePicker,
      child: Container(
        height: 220,
        width: double.infinity,
        decoration: BoxDecoration(
          color: Colors.blueGrey.shade900,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.video_call, size: 50, color: Colors.white38),
              const SizedBox(height: 8),
              const Text(
                'Tap to select a video or record one',
                style: TextStyle(color: Colors.white38),
              ),
              if (_pickError != null) ...[
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Text(
                    _pickError!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B1120),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0B1120),
        title: const Text('New Post', style: TextStyle(color: Colors.white)),
        actions: [
          TextButton(
            onPressed: () {
              if (!authController.requireAccount(context)) return;
              if (_pickedFile == null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Pick a video first.')),
                );
                return;
              }

              final me = authController.currentUser!;
              final caption = _captionController.text.trim();

              videoFeedStore.addVideo(
                VideoItem(
                  id: DateTime.now().millisecondsSinceEpoch.toString(),
                  username: '@${me.username}',
                  caption: caption.isEmpty ? 'New video' : caption,
                  musicTrack:
                      _selectedMusicName ?? 'Original Sound - ${me.username}',
                  category: 'Style',
                  likes: 0,
                  comments: 0,
                  creatorAvatarUrl: me.avatarUrl,
                  mediaUrl: _pickedFile!.path,
                ),
              );

              // TODO: also upload _pickedFile to real storage (Firebase
              // Storage, S3, etc.) here once a backend is connected - right
              // now the video only lives in this session's memory.

              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Posted! Check the feed or your profile.'),
                ),
              );
              Navigator.pop(context);
            },
            child: const Text(
              'Post',
              style: TextStyle(color: Colors.cyanAccent),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildPreviewArea(),
            const SizedBox(height: 10),
            if (_pickedFile != null)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: _showSourcePicker,
                  icon: const Icon(Icons.swap_horiz, color: Colors.cyanAccent),
                  label: const Text(
                    'Change video',
                    style: TextStyle(color: Colors.cyanAccent),
                  ),
                ),
              ),
            const SizedBox(height: 12),
            const Text(
              'Filters',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 40,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _filters.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, i) {
                  final selected = _filters[i] == _filter;
                  return ChoiceChip(
                    label: Text(_filters[i]),
                    selected: selected,
                    selectedColor: const Color(0xFF0284C7),
                    labelStyle: TextStyle(
                      color: selected ? Colors.white : Colors.white70,
                    ),
                    backgroundColor: Colors.black26,
                    onSelected: (_) => setState(() => _filter = _filters[i]),
                  );
                },
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'Music',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.cyan.shade600),
              ),
              child: Row(
                children: [
                  const Icon(Icons.music_note, color: Colors.cyanAccent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _selectedMusicName ?? 'Original Sound',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                  TextButton(
                    onPressed: _pickMusic,
                    child: const Text(
                      'Choose from phone',
                      style: TextStyle(color: Colors.cyanAccent),
                    ),
                  ),
                  if (_selectedMusicName != null)
                    IconButton(
                      icon: const Icon(
                        Icons.close,
                        color: Colors.white54,
                        size: 18,
                      ),
                      onPressed: () =>
                          setState(() => _selectedMusicName = null),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'Brightness',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            Slider(
              value: _brightness,
              activeColor: Colors.cyanAccent,
              onChanged: (v) => setState(() => _brightness = v),
            ),
            const Text(
              'Playback Speed',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            Slider(
              value: _speed,
              min: 0.5,
              max: 2.0,
              activeColor: Colors.cyanAccent,
              label: '${_speed.toStringAsFixed(1)}x',
              onChanged: (v) {
                setState(() => _speed = v);
                _videoController?.setPlaybackSpeed(v);
              },
            ),
            const SizedBox(height: 10),
            const Text(
              'Caption',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _captionController,
              maxLines: 3,
              style: const TextStyle(
                color: Color(0xFF1E293B),
                fontStyle: FontStyle.italic,
              ),
              decoration: InputDecoration(
                filled: true,
                fillColor: const Color(0xFFFDF6E3),
                hintText: 'Write a caption... it will look hand-written',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
