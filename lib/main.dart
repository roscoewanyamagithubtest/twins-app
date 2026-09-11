import 'dart:io';
import 'dart:ui';
import 'dart:typed_data';
import 'dart:convert';
import 'dart:math' show log;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show TapGestureRecognizer;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;

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

// ---------------------------------------------------------------------------
// DATABASE-READINESS NOTE
//
// AuthController and VideoFeedStore (below) are currently in-memory only -
// everything resets when the app restarts. Both are already structured as
// a single, app-wide seam (one controller, one store) specifically so that
// swapping in a real database later touches ONE place instead of scattering
// database calls through every screen. When you're ready to connect
// Firebase (the natural fit, since the auth methods already mirror
// Firebase Auth's shape) or another backend:
//
//   AuthController.signUp/signIn/signInWithGoogle -> replace the in-memory
//     Map lookups with FirebaseAuth calls (createUserWithEmailAndPassword,
//     signInWithEmailAndPassword, signInWithCredential), and mirror each
//     signed-up user into a 'users' collection in Firestore.
//
//   VideoFeedStore.videos / addVideo -> replace the in-memory List with a
//     Firestore collection ('videos'), addVideo becomes a
//     .add()/.set() call, and _videos should become a StreamBuilder
//     listening to the collection instead of a plain getter.
//
//   Likes/follows/messages (scattered across VideoItem's mutable fields)
//     -> each becomes a subcollection or field update in Firestore,
//     ideally wrapped in a transaction for counts (likes, followers) so
//     concurrent users don't overwrite each other's increments.
// ---------------------------------------------------------------------------
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

  /// Permanently deletes the current account: removes it from the
  /// in-memory account list, deletes every video they've posted from the
  /// shared feed, and signs them out. In a real backend, this should also
  /// delete their Firestore user document, uploaded media in Storage, and
  /// any messages - deleting an account should remove ALL their data, not
  /// just sign them out.
  void deleteAccount() {
    final me = currentUser;
    if (me == null) return;
    _accounts.remove(me.email);
    videoFeedStore.videos.removeWhere((v) => v.username == '@${me.username}');
    videoFeedStore.notifyListeners();
    currentUser = null;
    notifyListeners();
  }

  /// Call before any restricted action. Returns true if allowed to proceed;
  /// otherwise shows a sign-up prompt and returns false.
  bool requireAccount(BuildContext context) {
    if (!isGuest) return true;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF121212),
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
// ---------------------------------------------------------------------------
// TERMS OF SERVICE / PRIVACY POLICY
//
// IMPORTANT before publishing: this in-app text is a starting template,
// not a substitute for a real, hosted privacy policy. Google Play and
// Apple both require a live URL to your privacy policy in your store
// listing - a page shown only inside the app doesn't satisfy that. Once
// you're ready to publish, host this text (or a lawyer-reviewed version
// of it) at a real URL (e.g. a simple page on your own domain, or a free
// host like GitHub Pages - which you already have set up) and add that
// link to your Play Console / App Store Connect listing.
// ---------------------------------------------------------------------------
const String kTermsOfServiceText = '''
Twins - Terms of Service (template)

By creating an account, you agree to:
- Only post videos and photos you own or have permission to share.
- Not upload content that is illegal, harassing, hateful, sexually explicit involving minors, or otherwise violates applicable law.
- Respect other users - no harassment, impersonation, or spam.
- Understand that celebrity accounts require verification and a paid subscription.
- Understand that your account may be suspended or removed for violating these terms.

This is a template - replace it with a real Terms of Service, ideally reviewed by a lawyer, before publishing your app.
''';

const String kPrivacyPolicyText = '''
Twins - Privacy Policy (template)

We collect:
- Account info you provide (username, email).
- Content you upload (videos, photos, captions, messages).
- Basic usage data to keep the app working.

If you use look-alike matching, your photo may be analyzed by a third-party face-matching service to find similar faces. You can decline to use this feature.

We do not sell your personal data. Messages between users are stored to enable the messaging feature.

This is a template - replace it with a real Privacy Policy, ideally reviewed by a lawyer, before publishing your app. It must be hosted at a public URL for Play Store / App Store submission, not just shown inside the app.
''';

class LegalScreen extends StatelessWidget {
  final String title;
  final String body;
  const LegalScreen({super.key, required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF000000),
      appBar: AppBar(
        backgroundColor: const Color(0xFF000000),
        title: Text(title, style: const TextStyle(color: Colors.white)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Text(
          body,
          style: const TextStyle(color: Colors.white70, height: 1.5),
        ),
      ),
    );
  }
}

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
  bool _agreedToTerms = false;
  String? _error;

  static final _emailRegex = RegExp(r'^[\w\.\-]+@([\w\-]+\.)+[\w\-]{2,}$');

  String? _validate() {
    if (_usernameController.text.trim().length < 3) {
      return 'Username must be at least 3 characters.';
    }
    if (!_emailRegex.hasMatch(_emailController.text.trim())) {
      return 'Please enter a valid email address.';
    }
    if (_passwordController.text.length < 6) {
      return 'Password must be at least 6 characters.';
    }
    if (!_agreedToTerms) {
      return 'Please agree to the Terms of Service and Privacy Policy.';
    }
    return null;
  }

  void _submit() {
    final validationError = _validate();
    if (validationError != null) {
      setState(() => _error = validationError);
      return;
    }
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
    if (!_agreedToTerms) {
      setState(
        () =>
            _error = 'Please agree to the Terms of Service and Privacy Policy.',
      );
      return;
    }
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
      backgroundColor: const Color(0xFF000000),
      appBar: AppBar(
        backgroundColor: const Color(0xFF000000),
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
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Checkbox(
                    value: _agreedToTerms,
                    activeColor: const Color(0xFF0284C7),
                    onChanged: (v) =>
                        setState(() => _agreedToTerms = v ?? false),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: RichText(
                        text: TextSpan(
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                          ),
                          children: [
                            const TextSpan(text: 'I agree to the '),
                            TextSpan(
                              text: 'Terms of Service',
                              style: const TextStyle(
                                color: Colors.cyanAccent,
                                decoration: TextDecoration.underline,
                              ),
                              recognizer: TapGestureRecognizer()
                                ..onTap = () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => const LegalScreen(
                                      title: 'Terms of Service',
                                      body: kTermsOfServiceText,
                                    ),
                                  ),
                                ),
                            ),
                            const TextSpan(text: ' and '),
                            TextSpan(
                              text: 'Privacy Policy',
                              style: const TextStyle(
                                color: Colors.cyanAccent,
                                decoration: TextDecoration.underline,
                              ),
                              recognizer: TapGestureRecognizer()
                                ..onTap = () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => const LegalScreen(
                                      title: 'Privacy Policy',
                                      body: kPrivacyPolicyText,
                                    ),
                                  ),
                                ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
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

  void _showForgotPasswordDialog() {
    final resetEmailController = TextEditingController(
      text: _emailController.text,
    );
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF121212),
        title: const Text(
          'Reset Password',
          style: TextStyle(color: Colors.white),
        ),
        content: TextField(
          controller: resetEmailController,
          keyboardType: TextInputType.emailAddress,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            labelText: 'Your account email',
            labelStyle: TextStyle(color: Colors.white70),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text(
              'Cancel',
              style: TextStyle(color: Colors.white54),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0284C7),
            ),
            onPressed: () {
              // TODO: once a real backend is connected, call its password
              // reset endpoint here (e.g. Firebase Auth's
              // sendPasswordResetEmail). There's no email-sending
              // capability yet, so this just confirms the request.
              Navigator.pop(dialogContext);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    'If ${resetEmailController.text.trim()} has an account, a reset link will be sent (once email sending is connected).',
                  ),
                ),
              );
            },
            child: const Text('Send reset link'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF000000),
      appBar: AppBar(
        backgroundColor: const Color(0xFF000000),
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
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: _showForgotPasswordDialog,
                  child: const Text(
                    'Forgot password?',
                    style: TextStyle(color: Colors.cyanAccent, fontSize: 13),
                  ),
                ),
              ),
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
      backgroundColor: const Color(0xFF000000),
      appBar: AppBar(
        backgroundColor: const Color(0xFF000000),
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
                    tooltip: 'Send message',
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
        scaffoldBackgroundColor: const Color(0xFF000000),
        primaryColor: const Color(0xFF0284C7),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF0284C7),
          secondary: Color(0xFF38BDF8),
          surface: Color(0xFF121212),
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

  // Total USD tipped to this creator (Celebrities page tipping feature).
  int tipsReceivedUsd;

  // The actual picked video - a local file path (Android/iOS/desktop) or
  // a blob: URL (web). Null for the built-in demo videos, which show a
  // placeholder instead since there's no real media file behind them.
  final String? mediaUrl;

  // Which visual filter to render this video with (applied live in the
  // player - see kFilterMatrices). 'None' means no filter.
  final String filter;

  // Celebrity videos are shown only inside the Celebrities tab, with a
  // blue verified tick, and are excluded from the normal scrolling feed
  // unless the person searches for them directly.
  final bool isCelebrity;

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
    this.tipsReceivedUsd = 0,
    List<String>? messages,
    this.mediaUrl,
    this.filter = 'None',
    this.isCelebrity = false,
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
    VideoItem(
      id: '4',
      username: '@fitwithjade',
      caption: 'My gym buddy turned out to be my 87% twin!',
      musicTrack: 'Workout Mix - Pump It',
      category: 'Fitness',
      likes: 18700,
      comments: 412,
      followers: 12300,
      following: 145,
      accountLikes: 203000,
      reposts: 780,
      videoCount: 19,
    ),
    VideoItem(
      id: '5',
      username: '@wanderlust_theo',
      caption: 'Met my look-alike backpacking through Peru - 82% match!',
      musicTrack: 'Travel Vibes - Sunset Road',
      category: 'Travel',
      likes: 22100,
      comments: 566,
      followers: 15800,
      following: 203,
      accountLikes: 289000,
      reposts: 940,
      videoCount: 27,
    ),
    VideoItem(
      id: '6',
      username: '@comedyking_pj',
      caption: 'POV: you find your twin and he steals your jokes 😂',
      musicTrack: 'Funny Bit - Laugh Track',
      category: 'Comedy',
      likes: 34500,
      comments: 1203,
      followers: 19600,
      following: 88,
      accountLikes: 410000,
      reposts: 1560,
      videoCount: 41,
    ),
    VideoItem(
      id: '7',
      username: '@actorlife_maya',
      caption: 'My acting double showed up to my own audition - 90%!',
      musicTrack: 'Dramatic Score - Spotlight',
      category: 'Acting',
      likes: 15900,
      comments: 388,
      followers: 9700,
      following: 132,
      accountLikes: 176000,
      reposts: 620,
      videoCount: 16,
    ),
    VideoItem(
      id: '8',
      username: '@faithwithgrace',
      caption: 'Praise report: found my church twin - 85% match, glory!',
      musicTrack: 'Worship Mix - Amazing Grace',
      category: 'Gospel',
      likes: 27300,
      comments: 701,
      followers: 16400,
      following: 74,
      accountLikes: 305000,
      reposts: 1100,
      videoCount: 23,
    ),
    VideoItem(
      id: 'celeb-1',
      username: '@zaraofficial',
      caption: 'My twin match blew my mind - 96%! Who else has one?',
      musicTrack: 'Studio Mix - Zara',
      category: 'Music',
      likes: 892000,
      comments: 41200,
      followers: 4200000,
      following: 12,
      accountLikes: 15600000,
      reposts: 98000,
      videoCount: 61,
      isCelebrity: true,
    ),
    VideoItem(
      id: 'celeb-2',
      username: '@marcusthesprinter',
      caption: 'Fans keep sending me my "twin" - 91% match, wild!',
      musicTrack: 'Stadium Anthem - Official',
      category: 'Sports',
      likes: 654000,
      comments: 28900,
      followers: 3100000,
      following: 8,
      accountLikes: 9800000,
      reposts: 52000,
      videoCount: 44,
      isCelebrity: true,
    ),
    VideoItem(
      id: 'celeb-3',
      username: '@ceciliaonscreen',
      caption: 'Found out I have a 94% look-alike in Manila!',
      musicTrack: 'Cinematic Score - Reel Life',
      category: 'Movies',
      likes: 721000,
      comments: 33500,
      followers: 5600000,
      following: 15,
      accountLikes: 21000000,
      reposts: 87000,
      videoCount: 73,
      isCelebrity: true,
    ),
    VideoItem(
      id: 'celeb-4',
      username: '@joeycracksup',
      caption: 'My stand-up double roasted ME at my own show - 93%!',
      musicTrack: 'Funny Bit - Laugh Track',
      category: 'Comedy',
      likes: 583000,
      comments: 52100,
      followers: 2900000,
      following: 22,
      accountLikes: 8700000,
      reposts: 61000,
      videoCount: 38,
      isCelebrity: true,
    ),
    VideoItem(
      id: 'celeb-5',
      username: '@runwayrenee',
      caption: 'Backstage at fashion week I met my 97% twin!',
      musicTrack: 'Runway Beat - Vogue Mix',
      category: 'Fashion',
      likes: 1100000,
      comments: 61200,
      followers: 7300000,
      following: 19,
      accountLikes: 31000000,
      reposts: 142000,
      videoCount: 96,
      isCelebrity: true,
    ),
  ];

  void addVideo(VideoItem video) {
    videos.add(video);
    notifyListeners();
  }
}

final videoFeedStore = VideoFeedStore();

// ---------------------------------------------------------------------------
// LOOK-ALIKE MATCHING API CONFIG
//
// FILL THESE IN when your backend (e.g. an AWS Lambda function in front of
// Rekognition's IndexFaces/SearchFacesByImage) is ready. Leave them blank
// to keep using the built-in demo scorer in the meantime - the app works
// either way, you're just not getting real face-matching results yet.
// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// TRENDING ALGORITHM
//
// Ranks videos/celebrities by weighted engagement, not just raw follower
// count - a comment or a tip is a stronger signal of genuine interest than
// a passive like, so they count for more. Followers are included as a
// baseline authority signal but log-scaled so a huge existing following
// alone can't completely drown out genuinely trending newer content.
//
// Honest limitation: a truly production-grade trending algorithm also
// factors RECENCY/VELOCITY (engagement per hour, not just totals) so
// something popular yesterday doesn't outrank something exploding right
// now. This app doesn't track post timestamps yet, so this is a
// weighted-engagement approximation - add a `postedAt` field to VideoItem
// and factor in engagement-since-post-time here once that's tracked.
// ---------------------------------------------------------------------------
double calculateTrendingScore(VideoItem v) {
  return (v.likes * 1.0) +
      (v.comments * 3.0) +
      (v.reposts * 5.0) +
      (v.tipsReceivedUsd * 20.0) +
      (log(v.followers + 1) * 500);
}

class MatchingApiConfig {
  /// Your backend's base URL, e.g. 'https://abc123.execute-api.us-east-1.amazonaws.com'
  static const String baseUrl = '';

  /// A shared secret your Lambda checks for, sent as the x-api-key header.
  /// Never put your actual AWS/Rekognition credentials here - those stay
  /// server-side only. This key just authenticates your app to YOUR
  /// backend.
  static const String apiKey = '';

  static bool get isConfigured => baseUrl.isNotEmpty;
}

/// Result of a look-alike search - either from the real API or the demo
/// fallback.
class MatchResult {
  final int percentage;
  final String? matchedUsername;
  final String? matchedAvatarUrl;
  final bool isRealMatch; // false = demo fallback, true = real API result

  MatchResult({
    required this.percentage,
    this.matchedUsername,
    this.matchedAvatarUrl,
    this.isRealMatch = false,
  });
}

// ---------------------------------------------------------------------------
// LOOK-ALIKE MATCHING API SERVICE
//
// This is the ONE place in the app that produces a match percentage.
// Every screen (New Match, Celebrity badges) calls through here instead of
// inventing its own number, so wiring up a real backend is a one-file
// change.
//
// HOW TO CONNECT A REAL BACKEND (see the AWS conversation for the plan):
//   1. Set up an AWS Rekognition Face Collection.
//   2. Deploy two Lambda functions behind API Gateway:
//        POST /index   - takes a photo, calls IndexFaces, stores the
//                         returned FaceId against the user's account
//        POST /match   - takes a photo, calls SearchFacesByImage, returns
//                         the closest matching user's id + similarity %
//   3. Fill in MatchingApiConfig.baseUrl and apiKey above.
//   4. That's it - findLookAlike() and findCelebrityLookAlike() below
//      will automatically start hitting your real endpoints instead of
//      the demo fallback.
// ---------------------------------------------------------------------------
class MatchingApiService {
  /// DEMO FALLBACK - deterministic per pair of ids (so the same two
  /// accounts always show the same %) but NOT based on any actual visual
  /// comparison. Used automatically whenever MatchingApiConfig isn't
  /// filled in yet, or if a real API call fails, so the app never breaks
  /// during testing.
  static int _demoPercentageFor(String idA, String idB) {
    final combined = (idA + idB).hashCode.abs();
    return 75 + (combined % 22); // 75-96%, demo range only
  }

  /// Find the closest look-alike among everyday users. Pass the photo you
  /// want to search with (e.g. the person's profile picture bytes).
  static Future<MatchResult> findLookAlike({
    required String myId,
    Uint8List? photoBytes,
  }) async {
    if (!MatchingApiConfig.isConfigured || photoBytes == null) {
      return MatchResult(percentage: _demoPercentageFor(myId, 'new_match'));
    }
    try {
      final response = await http
          .post(
            Uri.parse('${MatchingApiConfig.baseUrl}/match'),
            headers: {
              'Content-Type': 'application/json',
              'x-api-key': MatchingApiConfig.apiKey,
            },
            body: jsonEncode({'photoBase64': base64Encode(photoBytes)}),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return MatchResult(
          percentage: (data['percentage'] as num).round(),
          matchedUsername: data['matchedUsername'] as String?,
          matchedAvatarUrl: data['matchedAvatarUrl'] as String?,
          isRealMatch: true,
        );
      }
    } catch (_) {
      // Falls through to the demo result below - network issues or a
      // not-yet-deployed backend should never crash the app.
    }
    return MatchResult(percentage: _demoPercentageFor(myId, 'new_match'));
  }

  /// Same idea, but searched against the celebrity collection instead of
  /// everyday users.
  static Future<MatchResult> findCelebrityLookAlike({
    required String myId,
    required String celebrityVideoId,
    Uint8List? photoBytes,
  }) async {
    if (!MatchingApiConfig.isConfigured || photoBytes == null) {
      return MatchResult(
        percentage: _demoPercentageFor(myId, celebrityVideoId),
      );
    }
    try {
      final response = await http
          .post(
            Uri.parse('${MatchingApiConfig.baseUrl}/match-celebrity'),
            headers: {
              'Content-Type': 'application/json',
              'x-api-key': MatchingApiConfig.apiKey,
            },
            body: jsonEncode({'photoBase64': base64Encode(photoBytes)}),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return MatchResult(
          percentage: (data['percentage'] as num).round(),
          matchedUsername: data['matchedUsername'] as String?,
          matchedAvatarUrl: data['matchedAvatarUrl'] as String?,
          isRealMatch: true,
        );
      }
    } catch (_) {
      // Same graceful fallback as above.
    }
    return MatchResult(percentage: _demoPercentageFor(myId, celebrityVideoId));
  }
}

// ---------------------------------------------------------------------------
// PAYMENT CONFIG & SERVICE
//
// FILL THESE IN when you're ready to take real payments. Recommended path:
// add the `purchases_flutter` package (RevenueCat) or `flutter_stripe`,
// then replace the body of purchaseCelebritySubscription() with a real
// checkout call. Until then, this simulates a successful purchase after a
// short delay so you can test the rest of the flow (account creation,
// unlocking the celebrity badge, etc.) end-to-end.
//
// NEVER put real secret API keys directly in this file for a published
// app - secret keys belong on your backend. Stripe's PUBLISHABLE key (not
// the secret key) is safe to ship in a mobile app; RevenueCat's public SDK
// key is also safe client-side.
// ---------------------------------------------------------------------------
class PaymentConfig {
  /// e.g. Stripe publishable key ('pk_live_...') or RevenueCat public SDK key.
  static const String publicApiKey = '';

  static bool get isConfigured => publicApiKey.isNotEmpty;
}

class PaymentService {
  /// Returns true on a successful purchase. Currently simulates success
  /// after a short delay when PaymentConfig isn't filled in yet, so the
  /// rest of the app (account creation, celebrity unlock) can be tested
  /// without a real payment provider connected.
  static Future<bool> purchaseCelebritySubscription() async {
    if (!PaymentConfig.isConfigured) {
      await Future.delayed(const Duration(milliseconds: 900));
      return true; // TESTING ONLY - replace once a real provider is wired in
    }
    // TODO: real checkout call, e.g.:
    //   final result = await Purchases.purchasePackage(celebrityPackage);
    //   return result.customerInfo.entitlements.active.containsKey('celebrity');
    return true;
  }
}

// ---------------------------------------------------------------------------
// TIPPING (Celebrities page) - API-ready
//
// Lets people send a real monetary tip to a celebrity, TikTok-gifting
// style. Uses the SAME PaymentConfig above (one payment provider for the
// whole app) - reuses whatever key you fill in there. Until that's
// configured, tips simulate success so you can test the full flow (pick
// amount, confirm, see it reflected) end-to-end today.
// ---------------------------------------------------------------------------
class TippingService {
  static const List<int> presetAmounts = [1, 5, 10, 25, 50];

  /// Returns true on a successful tip. Real integration note: charge the
  /// tipper via your payment provider, then credit the celebrity's payout
  /// balance on your backend (never trust the client to report success -
  /// verify the charge server-side before crediting anyone).
  static Future<bool> sendTip({
    required String celebrityId,
    required int amountUsd,
  }) async {
    if (!PaymentConfig.isConfigured) {
      await Future.delayed(const Duration(milliseconds: 700));
      return true; // TESTING ONLY - replace once a real provider is wired in
    }
    // TODO: real charge + payout call, e.g.:
    //   final charge = await Purchases.purchaseProduct('tip_$amountUsd');
    //   if (!charge.success) return false;
    //   await yourBackend.creditCelebrity(celebrityId, amountUsd);
    return true;
  }
}

// ---------------------------------------------------------------------------
// VIDEO FILTERS
//
// Applied live via ColorFiltered, both while previewing/recording in the
// upload screen and when the posted video plays back in any feed. Note:
// this recolors the video on-screen every time it plays - it does not
// permanently re-encode the pixels of the underlying video file (that
// would require server-side or native video processing, e.g. ffmpeg,
// which is a much bigger addition than a single Dart file).
// ---------------------------------------------------------------------------
const Map<String, List<double>> kFilterMatrices = {
  'None': [1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0],
  'Warm': [
    1.15,
    0,
    0,
    0,
    10,
    0,
    1.05,
    0,
    0,
    5,
    0,
    0,
    0.85,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ],
  'Cool': [0.9, 0, 0, 0, 0, 0, 1.0, 0, 0, 0, 0, 0, 1.2, 0, 10, 0, 0, 0, 1, 0],
  'B&W': [
    0.33,
    0.33,
    0.33,
    0,
    0,
    0.33,
    0.33,
    0.33,
    0,
    0,
    0.33,
    0.33,
    0.33,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ],
  'Vivid': [
    1.3,
    -0.1,
    -0.1,
    0,
    0,
    -0.1,
    1.3,
    -0.1,
    0,
    0,
    -0.1,
    -0.1,
    1.3,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ],
};

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
  // The normal feed excludes celebrity videos - those only live inside the
  // Celebrities tab (or turn up if someone searches for them directly).
  // Selecting a category from the scrollable wheel filters this list down
  // to just that category's videos - 'All' shows everything.
  List<VideoItem> get _videos {
    final base = videoFeedStore.videos.where((v) => !v.isCelebrity);
    final filtered = _selectedCategory == 'All'
        ? base
        : base.where((v) => v.category == _selectedCategory);
    return filtered.toList();
  }

  final List<String> _categories = [
    'All',
    'Dancing',
    'Style',
    'Fashion',
    'Fitness',
    'Travel',
    'Comedy',
    'Acting',
    'Gospel',
  ];

  String _selectedCategory = 'All';
  // Which item the wheel is currently scrolled to (just visual feedback
  // while scrolling) - separate from _selectedCategory, which only
  // changes when the person actually TAPS an item. This is what fixes
  // categories auto-applying mid-scroll.
  int _highlightedCategoryIndex = 0;
  int _currentIndex = 0;

  VideoItem get _currentVideo => _videos.isEmpty
      ? _placeholderVideo
      : _videos[_currentIndex.clamp(0, _videos.length - 1)];

  // Shown only if a category filter genuinely has zero videos in it, so
  // _currentVideo never crashes on an empty list.
  static final VideoItem _placeholderVideo = VideoItem(
    id: 'placeholder',
    username: '@twins',
    caption: 'No videos in this category yet - be the first to post one!',
    musicTrack: 'Original Sound',
    category: 'All',
    likes: 0,
    comments: 0,
  );

  // Tracks each visible video's live VideoPlayerController so the scrub
  // line can show/seek playback position.
  final Map<String, VideoPlayerController> _videoControllers = {};

  void _registerController(String videoId, VideoPlayerController? controller) {
    if (controller == null) {
      _videoControllers.remove(videoId);
    } else {
      _videoControllers[videoId] = controller;
    }
    if (mounted) setState(() {});
  }

  // These start at a reasonable placeholder and get replaced with a real
  // result from MatchingApiService as soon as it resolves (instant if
  // running on the demo fallback, or after the real API responds once a
  // backend is connected).
  int _newMatchPercent = 80;
  int _celebMatchPercent = 94;

  Future<void> _loadMatchPercentages() async {
    final myId = authController.currentUser?.username ?? 'guest';
    final photoBytes = authController.currentUser?.avatarBytes;

    final newMatchResult = await MatchingApiService.findLookAlike(
      myId: myId,
      photoBytes: photoBytes,
    );
    if (mounted) setState(() => _newMatchPercent = newMatchResult.percentage);

    final celebResult = await MatchingApiService.findCelebrityLookAlike(
      myId: myId,
      celebrityVideoId: 'locked_celeb',
      photoBytes: photoBytes,
    );
    if (mounted) setState(() => _celebMatchPercent = celebResult.percentage);
  }

  MatchProfile get _newMatch => MatchProfile(
    name: 'Rafael M.',
    country: 'Brazil',
    percentage: _newMatchPercent,
    imageUrl: 'https://i.pravatar.cc/400?img=32',
  );

  MatchProfile get _celebMatch => MatchProfile(
    name: 'Locked Celebrity',
    country: 'USA',
    percentage: _celebMatchPercent,
    isCelebrity: true,
    locked: true,
  );

  @override
  void initState() {
    super.initState();
    // Rebuild the feed whenever a new video is posted anywhere in the app.
    videoFeedStore.addListener(_onFeedChanged);
    _loadMatchPercentages();
  }

  void _onFeedChanged() {
    if (mounted) setState(() {});
  }

  // Resets everything back to the very first, unfiltered view of the app -
  // used by both the "Twins" logo (always visible, top bar) and the
  // "For You" chip that appears while a category filter is active.
  void _goHome() {
    setState(() {
      _selectedCategory = 'All';
      _highlightedCategoryIndex = _categories.indexOf('All');
      _currentIndex = 0;
    });
    if (_pageController.hasClients) {
      _pageController.jumpToPage(0);
    }
    if (_categoryWheelController.hasClients) {
      _categoryWheelController.jumpToItem(_categories.indexOf('All'));
    }
  }

  // Actually applies a category filter - only called when the person TAPS
  // an item in the wheel, never just from scrolling past it.
  void _applyCategory(int index) {
    setState(() {
      _selectedCategory = _categories[index];
      _highlightedCategoryIndex = index;
      _currentIndex = 0;
    });
    if (_pageController.hasClients) {
      _pageController.jumpToPage(0);
    }
    if (_categoryWheelController.hasClients) {
      _categoryWheelController.animateToItem(
        index,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  // Is this video one of the top 3 trending (by calculateTrendingScore)
  // within whatever's currently being browsed? Same algorithm the
  // Celebrities leaderboard uses, applied here for app-wide consistency.
  bool _isTrending(VideoItem video) {
    final pool = [..._videos]
      ..sort(
        (a, b) =>
            calculateTrendingScore(b).compareTo(calculateTrendingScore(a)),
      );
    return pool.take(3).contains(video);
  }

  IconData _categoryIcon(String category) {
    switch (category) {
      case 'Dancing':
        return Icons.music_note;
      case 'Style':
        return Icons.checkroom;
      case 'Fashion':
        return Icons.style;
      case 'Fitness':
        return Icons.fitness_center;
      case 'Travel':
        return Icons.flight_takeoff;
      case 'Comedy':
        return Icons.theater_comedy;
      case 'Acting':
        return Icons.movie;
      case 'Gospel':
        return Icons.church;
      default:
        return Icons.apps; // 'All'
    }
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
  // SCRUB LINE - tiny draggable/tappable progress line under the video,
  // for nexting (seeking forward) and reversing (seeking back).
  // -------------------------------------------------------------------
  Widget _buildScrubLine(VideoItem video) {
    final controller = _videoControllers[video.id];
    if (controller == null || !controller.value.isInitialized) {
      return const SizedBox(height: 3);
    }
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: controller,
      builder: (context, value, child) {
        final durationMs = value.duration.inMilliseconds;
        final positionMs = value.position.inMilliseconds;
        final progress = durationMs > 0 ? positionMs / durationMs : 0.0;
        return LayoutBuilder(
          builder: (context, constraints) {
            void seekToLocalX(double dx) {
              final ratio = (dx / constraints.maxWidth).clamp(0.0, 1.0);
              controller.seekTo(
                Duration(milliseconds: (ratio * durationMs).round()),
              );
            }

            return GestureDetector(
              onTapUp: (d) => seekToLocalX(d.localPosition.dx),
              onHorizontalDragUpdate: (d) => seekToLocalX(d.localPosition.dx),
              child: Container(
                height: 8,
                alignment: Alignment.center,
                color: Colors.transparent, // widen the tap target
                child: Container(
                  height: 3,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: progress.clamp(0.0, 1.0),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.cyanAccent,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  // -------------------------------------------------------------------
  // SHARE SHEET - sharable destinations + a Download option
  // -------------------------------------------------------------------
  void _showShareSheet(VideoItem video) {
    void shareVia(String label) {
      Navigator.pop(context);
      Share.share('Check out ${video.username} on Twins! "${video.caption}"');
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF121212),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Text(
                  'Share to',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ),
              SizedBox(
                height: 90,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    _shareTile(
                      Icons.chat,
                      'WhatsApp',
                      Colors.green,
                      () => shareVia('WhatsApp'),
                    ),
                    _shareTile(
                      Icons.facebook,
                      'Facebook',
                      Colors.blue,
                      () => shareVia('Facebook'),
                    ),
                    _shareTile(
                      Icons.camera_alt,
                      'Instagram',
                      Colors.purple,
                      () => shareVia('Instagram'),
                    ),
                    _shareTile(
                      Icons.send,
                      'Messenger',
                      Colors.indigo,
                      () => shareVia('Messenger'),
                    ),
                    _shareTile(Icons.link, 'Copy Link', Colors.grey, () {
                      Clipboard.setData(
                        ClipboardData(
                          text: 'https://twinsapp.example/v/${video.id}',
                        ),
                      );
                      Navigator.pop(context);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Link copied.')),
                      );
                    }),
                    _shareTile(
                      Icons.more_horiz,
                      'More',
                      Colors.white54,
                      () => shareVia('More'),
                    ),
                  ],
                ),
              ),
              const Divider(color: Colors.white12, height: 20),
              ListTile(
                leading: const Icon(Icons.download, color: Colors.cyanAccent),
                title: const Text(
                  'Download video',
                  style: TextStyle(color: Colors.white),
                ),
                subtitle: const Text(
                  'Includes the Twins watermark shown during playback',
                  style: TextStyle(color: Colors.white38, fontSize: 11),
                ),
                onTap: () async {
                  Navigator.pop(context);
                  if (video.mediaUrl == null) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'No downloadable file for this demo video.',
                        ),
                      ),
                    );
                    return;
                  }
                  try {
                    await Share.shareXFiles([
                      XFile(video.mediaUrl!),
                    ], text: 'Shared from Twins');
                  } catch (e) {
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Could not save video: $e')),
                    );
                  }
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.flag_outlined,
                  color: Colors.redAccent,
                ),
                title: const Text(
                  'Report',
                  style: TextStyle(color: Colors.white),
                ),
                subtitle: const Text(
                  'Flag this video for review',
                  style: TextStyle(color: Colors.white38, fontSize: 11),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _showReportSheet(video);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Reports go into an in-memory list for now - see the note on
  // AuthController/VideoFeedStore for how to wire real persistence in.
  // TODO: once a backend exists, POST this to a /reports endpoint (or a
  // Firestore 'reports' collection) so moderators can actually see it.
  void _showReportSheet(VideoItem video) {
    final reasons = [
      'Spam or misleading',
      'Nudity or sexual content',
      'Harassment or bullying',
      'Hate speech or symbols',
      'Violence or dangerous content',
      'Impersonation',
      'Something else',
    ];
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF121212),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Why are you reporting this video?',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            ...reasons.map(
              (reason) => ListTile(
                title: Text(
                  reason,
                  style: const TextStyle(color: Colors.white70),
                ),
                onTap: () {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Thanks - our team will review this video.',
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _shareTile(
    IconData icon,
    String label,
    Color color,
    VoidCallback onTap,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 22,
              backgroundColor: color,
              child: Icon(icon, color: Colors.white, size: 20),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: const TextStyle(color: Colors.white70, fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------------
  // CREATOR PROFILE SHEET (tap the round profile picture next to a video)
  // -------------------------------------------------------------------
  void _showCreatorProfileSheet(VideoItem video) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF121212),
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
      backgroundColor: const Color(0xFF000000),
      body: Stack(
        children: [
          // Vertical scrolling video feed
          _videos.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.videocam_off_outlined,
                          color: Colors.white24,
                          size: 56,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'No $_selectedCategory videos yet',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Be the first to post one, or pick another category.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white38, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                )
              : PageView.builder(
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

          // Top bar: logo/title + messages + search. Kept simple and clear
          // of the video's face area.
          SafeArea(child: Column(children: [_buildTopBar()])),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------
  // TOP BAR: Logo + Title + Search
  // -------------------------------------------------------------------
  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  // A real, clearly-visible back/home button - not just a
                  // tappable logo. Only does something when there's actually
                  // somewhere to go "back" to (a category filter applied).
                  IconButton(
                    icon: const Icon(
                      Icons.arrow_back,
                      color: Colors.white,
                      size: 20,
                    ),
                    tooltip: 'Back to For You',
                    onPressed: _selectedCategory == 'All' ? null : _goHome,
                    disabledColor: Colors.white24,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 34,
                      minHeight: 34,
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.mail_outline,
                      color: Colors.white,
                      size: 20,
                    ),
                    tooltip: 'Messages',
                    onPressed: () => _openMessageScreen(_currentVideo),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 34,
                      minHeight: 34,
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
              Row(
                children: [
                  Container(
                    width: 26,
                    height: 26,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: [Color(0xFF0284C7), Color(0xFF38BDF8)],
                      ),
                    ),
                    child: const Icon(
                      Icons.people_alt_rounded,
                      color: Colors.white,
                      size: 16,
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Text(
                    'Twins',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      fontSize: 18,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
              IconButton(
                icon: const Icon(Icons.search, color: Colors.white, size: 22),
                tooltip: 'Search',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const SearchScreen()),
                  );
                },
              ),
            ],
          ),
          // "Now watching: <category>" - only shown while a filter is
          // active, so people always know what they're browsing.
          if (_selectedCategory != 'All')
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: Colors.black45,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.cyan.shade600, width: 1),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _categoryIcon(_selectedCategory),
                      color: Colors.cyanAccent,
                      size: 12,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      'Watching: $_selectedCategory',
                      style: const TextStyle(
                        color: Colors.cyanAccent,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
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
        width: 60,
        height: 66,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF38BDF8), width: 1.2),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                child: _newMatch.imageUrl.isNotEmpty
                    ? Image.network(
                        _newMatch.imageUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) =>
                            Container(color: Colors.blueGrey.shade700),
                      )
                    : Container(color: Colors.blueGrey.shade700),
              ),
              Container(color: Colors.black.withValues(alpha: 0.35)),
              const Center(
                child: Icon(
                  Icons.remove_red_eye,
                  color: Colors.white70,
                  size: 16,
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(4.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Text(
                        '${_newMatch.percentage}% Match',
                        style: const TextStyle(
                          color: Colors.cyanAccent,
                          fontSize: 8,
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
                            fontSize: 9,
                          ),
                        ),
                        Row(
                          children: [
                            const Icon(
                              Icons.location_on,
                              color: Colors.redAccent,
                              size: 8,
                            ),
                            const SizedBox(width: 2),
                            Text(
                              _newMatch.country,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 7,
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
  // CELEBRITY BOX - free to browse, opens the celebrity-only feed
  // -------------------------------------------------------------------
  Widget _buildCelebrityBox() {
    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const CelebrityFeedScreen()),
        );
      },
      child: Container(
        width: 65,
        height: 77,
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
                padding: const EdgeInsets.all(4.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.amber,
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(
                            '${_celebMatch.percentage}%',
                            style: const TextStyle(
                              color: Colors.black,
                              fontSize: 8,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const Icon(
                          Icons.lock,
                          color: Colors.amberAccent,
                          size: 11,
                        ),
                        const SizedBox(width: 1),
                        const Icon(
                          Icons.verified,
                          color: Colors.blueAccent,
                          size: 11,
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
                            fontSize: 10,
                          ),
                        ),
                        Text(
                          'Unlock Twin',
                          style: TextStyle(color: Colors.white70, fontSize: 7),
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
  // SINGLE VIDEO PAGE
  // -------------------------------------------------------------------
  Widget _buildVideoPage(VideoItem video) {
    return Container(
      color: const Color(0xFF000000),
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
                ? _FeedVideoPlayer(
                    mediaUrl: video.mediaUrl!,
                    filter: video.filter,
                    onControllerChanged: (c) =>
                        _registerController(video.id, c),
                    isLiked: video.likedByMe,
                    onDoubleTapLike: () {
                      if (!video.likedByMe) _toggleLike(video);
                    },
                  )
                : const Center(
                    child: Icon(
                      Icons.play_circle_outline,
                      size: 80,
                      color: Colors.white30,
                    ),
                  ),
          ),

          // Trending badge - same weighted algorithm as the Celebrities
          // page leaderboard, shown when this video is one of the top 3
          // trending within whatever's currently being browsed.
          if (_isTrending(video))
            Positioned(
              top: 90,
              left: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Colors.amber, Colors.deepOrange],
                  ),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text(
                  '🔥 Trending',
                  style: TextStyle(
                    color: Colors.black,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),

          // Music / sound pill - sits just above the bottom row (now
          // taller since New Match / Celebrities moved into it), styled
          // transparent like the category wheel
          Positioned(
            left: 16,
            bottom: 118,
            child: GestureDetector(
              onTap: () => _showMusicSheet(video.musicTrack),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.music_note,
                      color: Colors.cyanAccent,
                      size: 14,
                    ),
                    const SizedBox(width: 4),
                    SizedBox(
                      width: 70,
                      child: Text(
                        video.musicTrack,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Scrub line for seeking forward/back through the video
          if (video.mediaUrl != null)
            Positioned(
              left: 16,
              right: 16,
              bottom: 105,
              child: _buildScrubLine(video),
            ),

          // Home - Caption - Share, all on the same line
          Positioned(
            left: 20,
            right: 20,
            bottom: 24,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                GestureDetector(
                  onTap: () {
                    _pageController.animateToPage(
                      0,
                      duration: const Duration(milliseconds: 400),
                      curve: Curves.easeInOut,
                    );
                  },
                  child: Tooltip(
                    message: 'Home - scroll to the top of your feed',
                    child: Container(
                      padding: const EdgeInsets.all(9),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.black87,
                        border: Border.all(color: Colors.cyan.shade600),
                      ),
                      child: const Icon(
                        Icons.home,
                        color: Colors.white,
                        size: 18,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                _buildNewMatchBox(),
                const SizedBox(width: 8),
                _buildCelebrityBox(),
                const SizedBox(width: 10),
                Expanded(
                  child: _buildRuledPaperCaption(
                    video,
                    compact: true,
                    onTap: () => _showFullCaption(video),
                  ),
                ),
                const SizedBox(width: 12),
                GestureDetector(
                  onTap: () => _showShareSheet(video),
                  child: Tooltip(
                    message: 'Share this video',
                    child: Container(
                      padding: const EdgeInsets.all(9),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.black87,
                        border: Border.all(color: Colors.cyan.shade600),
                      ),
                      child: const Icon(
                        Icons.share,
                        color: Colors.white,
                        size: 18,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Right side action rail
          Positioned(
            right: 12,
            bottom: 100,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Creator's avatar, with a follow badge (tap to follow).
                // Sits just above the + upload button, TikTok-style.
                GestureDetector(
                  onTap: () => _showCreatorProfileSheet(video),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      CircleAvatar(
                        radius: 20,
                        backgroundColor: const Color(0xFF0284C7),
                        backgroundImage: video.creatorAvatarUrl.isNotEmpty
                            ? NetworkImage(video.creatorAvatarUrl)
                            : null,
                        child: video.creatorAvatarUrl.isEmpty
                            ? const Icon(
                                Icons.person,
                                color: Colors.white,
                                size: 20,
                              )
                            : null,
                      ),
                      Positioned(
                        bottom: -6,
                        left: 12,
                        child: GestureDetector(
                          onTap: () => _toggleFollow(video),
                          child: Tooltip(
                            message: video.isFollowedByMe
                                ? 'Following - tap to unfollow'
                                : 'Follow ${video.username}',
                            child: Container(
                              width: 18,
                              height: 18,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: video.isFollowedByMe
                                    ? Colors.green
                                    : Colors.cyanAccent,
                                border: Border.all(
                                  color: const Color(0xFF000000),
                                  width: 2,
                                ),
                              ),
                              child: Icon(
                                video.isFollowedByMe
                                    ? Icons.check
                                    : Icons.electrical_services,
                                size: 11,
                                color: Colors.black,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const Text(
                  'Profile',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 8,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 14),
                GestureDetector(
                  onTap: () {
                    if (!authController.requireAccount(context)) return;
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const UploadScreen()),
                    );
                  },
                  child: Tooltip(
                    message: 'Post a new video',
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: const Color(0xFF0284C7),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.cyan.withValues(alpha: 0.5),
                            blurRadius: 8,
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.add,
                        color: Colors.white,
                        size: 22,
                      ),
                    ),
                  ),
                ),
                const Text(
                  'Post',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 8,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 28),
                if (_selectedCategory != 'All')
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: GestureDetector(
                      onTap: _goHome,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: Colors.cyanAccent),
                        ),
                        child: const Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.arrow_back,
                              color: Colors.cyanAccent,
                              size: 14,
                            ),
                            Text(
                              'For You',
                              style: TextStyle(
                                color: Colors.cyanAccent,
                                fontSize: 8,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                SizedBox(
                  height: 120,
                  width: 58,
                  child: ListWheelScrollView.useDelegate(
                    controller: _categoryWheelController,
                    itemExtent: 30,
                    perspective: 0.006,
                    diameterRatio: 1.2,
                    physics: const FixedExtentScrollPhysics(),
                    onSelectedItemChanged: (index) {
                      // Just updates which item looks highlighted while
                      // scrolling - does NOT filter the feed. Tap an item
                      // to actually apply it.
                      setState(() => _highlightedCategoryIndex = index);
                    },
                    childDelegate: ListWheelChildBuilderDelegate(
                      childCount: _categories.length,
                      builder: (context, catIndex) {
                        final isCentered =
                            catIndex == _highlightedCategoryIndex;
                        final isApplied =
                            _categories[catIndex] == _selectedCategory;
                        return GestureDetector(
                          onTap: () => _applyCategory(catIndex),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            curve: Curves.easeOut,
                            alignment: Alignment.center,
                            margin: EdgeInsets.symmetric(
                              horizontal: isCentered ? 0 : 4,
                              vertical: isCentered ? 0 : 2,
                            ),
                            decoration: BoxDecoration(
                              gradient: isCentered
                                  ? const LinearGradient(
                                      colors: [
                                        Color(0xFF0284C7),
                                        Color(0xFF38BDF8),
                                      ],
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                    )
                                  : null,
                              color: isCentered ? null : Colors.black26,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: isCentered
                                    ? Colors.cyanAccent
                                    : Colors.white12,
                                width: isCentered ? 1.4 : 1,
                              ),
                              boxShadow: isCentered
                                  ? [
                                      BoxShadow(
                                        color: Colors.cyan.withValues(
                                          alpha: 0.5,
                                        ),
                                        blurRadius: 8,
                                      ),
                                    ]
                                  : null,
                            ),
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      _categoryIcon(_categories[catIndex]),
                                      size: isCentered ? 14 : 11,
                                      color: isCentered
                                          ? Colors.white
                                          : Colors.white54,
                                    ),
                                    const SizedBox(height: 1),
                                    Text(
                                      _categories[catIndex],
                                      style: TextStyle(
                                        color: isCentered
                                            ? Colors.white
                                            : Colors.white60,
                                        fontSize: isCentered ? 8 : 7,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                                // Small dot marks whichever category is
                                // actually applied to the feed right now.
                                if (isApplied)
                                  const Positioned(
                                    top: 2,
                                    right: 2,
                                    child: Icon(
                                      Icons.circle,
                                      size: 5,
                                      color: Colors.amberAccent,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                IconButton(
                  icon: Icon(
                    video.likedByMe ? Icons.favorite : Icons.favorite_border,
                    color: Colors.redAccent,
                    size: 24,
                  ),
                  tooltip: video.likedByMe ? 'Unlike' : 'Like',
                  onPressed: () => _toggleLike(video),
                ),
                Text(
                  '${video.likes}',
                  style: const TextStyle(color: Colors.white, fontSize: 10),
                ),
                const SizedBox(height: 8),
                IconButton(
                  icon: const Icon(
                    Icons.chat_bubble_outline,
                    color: Colors.white,
                    size: 22,
                  ),
                  tooltip: 'Comments',
                  onPressed: () => _showCommentsSheet(video),
                ),
                Text(
                  '${video.comments}',
                  style: const TextStyle(color: Colors.white, fontSize: 10),
                ),
                const SizedBox(height: 8),
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
                    radius: 16,
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
                        fontSize: 10,
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
  Widget _buildRuledPaperCaption(
    VideoItem video, {
    bool compact = false,
    VoidCallback? onTap,
  }) {
    final words = video.caption.split(' ');
    final truncated = words.length > 6
        ? '${words.take(6).join(' ')}...'
        : video.caption;

    if (compact) {
      return GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFFFDF6E3).withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(20),
            border: Border(
              left: BorderSide(color: Colors.red.shade300, width: 2),
            ),
          ),
          child: Text(
            '${video.username}: $truncated',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.caveat(
              color: const Color(0xFF121212),
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
    }

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
                  color: const Color(0xFF121212),
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

  // Tapping the truncated caption pill opens the full caption like this.
  void _showFullCaption(VideoItem video) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Padding(
        padding: const EdgeInsets.all(20),
        child: _buildRuledPaperCaption(video),
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
      backgroundColor: const Color(0xFF121212),
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
            setSheetState(() => submitting = true);
            final paid = await PaymentService.purchaseCelebritySubscription();
            setSheetState(() => submitting = false);
            if (!sheetContext.mounted) return;
            if (!paid) {
              setSheetState(() => error = 'Payment failed. Please try again.');
              return;
            }
            Navigator.pop(sheetContext);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  PaymentConfig.isConfigured
                      ? 'Payment successful! Celebrities unlocked.'
                      : 'Payment simulated (no provider connected yet) - celebrities unlocked for testing.',
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
            if (googleError != null) {
              setSheetState(() {
                submitting = false;
                error = googleError;
              });
              return;
            }
            final paid = await PaymentService.purchaseCelebritySubscription();
            setSheetState(() => submitting = false);
            if (!sheetContext.mounted) return;
            if (!paid) {
              setSheetState(() => error = 'Payment failed. Please try again.');
              return;
            }
            Navigator.pop(sheetContext);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  PaymentConfig.isConfigured
                      ? 'Payment successful! Celebrities unlocked.'
                      : 'Payment simulated (no provider connected yet) - celebrities unlocked for testing.',
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
      backgroundColor: const Color(0xFF121212),
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
      backgroundColor: const Color(0xFF121212),
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
                          tooltip: 'Post comment',
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
  final String filter;
  final ValueChanged<VideoPlayerController?>? onControllerChanged;
  final VoidCallback? onDoubleTapLike;
  final bool isLiked;
  const _FeedVideoPlayer({
    required this.mediaUrl,
    this.filter = 'None',
    this.onControllerChanged,
    this.onDoubleTapLike,
    this.isLiked = false,
  });

  @override
  State<_FeedVideoPlayer> createState() => _FeedVideoPlayerState();
}

class _FeedVideoPlayerState extends State<_FeedVideoPlayer> {
  VideoPlayerController? _controller;
  bool _failed = false;
  bool _showTapIcon = false;
  IconData _tapIcon = Icons.pause;
  bool _showHeartBurst = false;
  bool _muted = false;

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
      widget.onControllerChanged?.call(controller);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    widget.onControllerChanged?.call(null);
    _controller?.dispose();
    super.dispose();
  }

  void _togglePlayback(VideoPlayerController controller) {
    final willPause = controller.value.isPlaying;
    setState(() {
      willPause ? controller.pause() : controller.play();
      _tapIcon = willPause ? Icons.pause : Icons.play_arrow;
      _showTapIcon = true;
    });
    Future.delayed(const Duration(milliseconds: 450), () {
      if (mounted) setState(() => _showTapIcon = false);
    });
  }

  void _toggleMute(VideoPlayerController controller) {
    setState(() {
      _muted = !_muted;
      controller.setVolume(_muted ? 0 : 1);
    });
  }

  // Double-tap anywhere on the video to like it, TikTok/Instagram-style -
  // shows a big heart burst regardless of whether this already liked it
  // (matches the platforms this is modeled on - a second double-tap just
  // re-plays the animation, it doesn't unlike).
  void _handleDoubleTap() {
    widget.onDoubleTapLike?.call();
    setState(() => _showHeartBurst = true);
    Future.delayed(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _showHeartBurst = false);
    });
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
      onTap: () => _togglePlayback(controller),
      onDoubleTap: _handleDoubleTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRect(
            child: ColorFiltered(
              colorFilter: ColorFilter.matrix(
                kFilterMatrices[widget.filter] ?? kFilterMatrices['None']!,
              ),
              child: FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: controller.value.size.width,
                  height: controller.value.size.height,
                  child: VideoPlayer(controller),
                ),
              ),
            ),
          ),
          Center(
            child: AnimatedOpacity(
              opacity: _showTapIcon ? 1 : 0,
              duration: const Duration(milliseconds: 150),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.black.withValues(alpha: 0.4),
                ),
                child: Icon(_tapIcon, color: Colors.white, size: 48),
              ),
            ),
          ),
          // Heart burst - double-tap-to-like feedback
          Center(
            child: AnimatedScale(
              scale: _showHeartBurst ? 1.0 : 0.4,
              duration: const Duration(milliseconds: 250),
              curve: Curves.elasticOut,
              child: AnimatedOpacity(
                opacity: _showHeartBurst ? 1 : 0,
                duration: const Duration(milliseconds: 250),
                child: const Icon(
                  Icons.favorite,
                  color: Colors.redAccent,
                  size: 90,
                ),
              ),
            ),
          ),
          // Mute toggle - top-left, small and unobtrusive
          Positioned(
            top: 10,
            left: 10,
            child: Tooltip(
              message: _muted ? 'Unmute' : 'Mute',
              child: GestureDetector(
                onTap: () => _toggleMute(controller),
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.black.withValues(alpha: 0.4),
                  ),
                  child: Icon(
                    _muted ? Icons.volume_off : Icons.volume_up,
                    color: Colors.white,
                    size: 16,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// SEARCH SCREEN
// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// CELEBRITY FEED SCREEN
//
// Free for anyone to browse. Shows ONLY videos flagged isCelebrity, each
// with a blue verified tick. These never appear in the normal scrolling
// feed. Creating an account here (posting as a celebrity) requires
// payment - browsing does not.
// ---------------------------------------------------------------------------
class CelebrityFeedScreen extends StatefulWidget {
  const CelebrityFeedScreen({super.key});

  @override
  State<CelebrityFeedScreen> createState() => _CelebrityFeedScreenState();
}

class _CelebrityFeedScreenState extends State<CelebrityFeedScreen> {
  final PageController _pageController = PageController();

  @override
  void initState() {
    super.initState();
    videoFeedStore.addListener(_onChanged);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    videoFeedStore.removeListener(_onChanged);
    _pageController.dispose();
    _celebCategoryWheelController.dispose();
    super.dispose();
  }

  String _selectedCelebCategory = 'All';
  int _highlightedCelebCategoryIndex = 0;
  final FixedExtentScrollController _celebCategoryWheelController =
      FixedExtentScrollController();
  final List<String> _celebCategories = [
    'All',
    'Music',
    'Sports',
    'Movies',
    'Comedy',
    'Fashion',
  ];

  void _applyCelebCategory(int index) {
    setState(() {
      _selectedCelebCategory = _celebCategories[index];
      _highlightedCelebCategoryIndex = index;
    });
    if (_pageController.hasClients) {
      _pageController.jumpToPage(0);
    }
    if (_celebCategoryWheelController.hasClients) {
      _celebCategoryWheelController.animateToItem(
        index,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  IconData _celebCategoryIcon(String category) {
    switch (category) {
      case 'Music':
        return Icons.music_note;
      case 'Sports':
        return Icons.sports_soccer;
      case 'Movies':
        return Icons.movie;
      case 'Comedy':
        return Icons.theater_comedy;
      case 'Fashion':
        return Icons.style;
      default:
        return Icons.apps; // 'All'
    }
  }

  List<VideoItem> get _allCelebVideos =>
      videoFeedStore.videos.where((v) => v.isCelebrity).toList();

  List<VideoItem> get _celebVideos {
    final all = _allCelebVideos;
    return _selectedCelebCategory == 'All'
        ? all
        : all.where((v) => v.category == _selectedCelebCategory).toList();
  }

  // Top Celebrities leaderboard - ranked by a weighted trending score
  // (see calculateTrendingScore), not just raw follower count, so genuine
  // engagement actually moves the rankings.
  List<VideoItem> get _topCelebrities {
    final sorted = [..._allCelebVideos]
      ..sort(
        (a, b) =>
            calculateTrendingScore(b).compareTo(calculateTrendingScore(a)),
      );
    return sorted.take(10).toList();
  }

  // Caches each celebrity video's real match % once fetched, so the
  // PageView (which builds synchronously) always has something to show
  // immediately while the real result loads in the background.
  final Map<String, int> _matchCache = {};

  int _matchPercentFor(VideoItem video) {
    final cached = _matchCache[video.id];
    if (cached != null) return cached;

    // Kick off the real (or demo-fallback) lookup in the background.
    MatchingApiService.findCelebrityLookAlike(
      myId: authController.currentUser?.username ?? 'guest',
      celebrityVideoId: video.id,
      photoBytes: authController.currentUser?.avatarBytes,
    ).then((result) {
      if (mounted) setState(() => _matchCache[video.id] = result.percentage);
    });

    // Instant placeholder shown for the first frame or two while that
    // resolves, so nothing ever looks broken or blank.
    return 75 + (video.id.hashCode.abs() % 22);
  }

  void _toggleFollow(VideoItem video) {
    if (!authController.requireAccount(context)) return;
    setState(() {
      video.isFollowedByMe = !video.isFollowedByMe;
      video.followers += video.isFollowedByMe ? 1 : -1;
    });
  }

  // Same profile sheet pattern as the For You page - tapping a
  // celebrity's avatar shows their stats, follow, message, and videos.
  void _showCelebProfileSheet(VideoItem video) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF121212),
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
                  Stack(
                    alignment: Alignment.center,
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
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        video.username,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Icon(
                        Icons.verified,
                        color: Colors.blueAccent,
                        size: 16,
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _celebProfileStat('Following', video.following),
                      _celebProfileStat('Followers', video.followers),
                      _celebProfileStat('Likes', video.accountLikes),
                      _celebProfileStat('Reposts', video.reposts),
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
                              : Colors.amber,
                        ),
                        onPressed: () {
                          _toggleFollow(video);
                          setSheetState(() {});
                        },
                        child: Text(
                          video.isFollowedByMe ? 'Following' : 'Follow',
                          style: TextStyle(
                            color: video.isFollowedByMe
                                ? Colors.white
                                : Colors.black,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Colors.cyanAccent),
                        ),
                        onPressed: () {
                          if (!authController.requireAccount(context)) return;
                          Navigator.pop(sheetContext);
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => MessageScreen(video: video),
                            ),
                          );
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
                      const SizedBox(width: 10),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Colors.amberAccent),
                        ),
                        onPressed: () {
                          Navigator.pop(sheetContext);
                          _showTipSheet(video);
                        },
                        icon: const Icon(
                          Icons.card_giftcard,
                          color: Colors.amberAccent,
                          size: 18,
                        ),
                        label: const Text(
                          'Tip',
                          style: TextStyle(color: Colors.amberAccent),
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

  Widget _celebProfileStat(String label, int value) {
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

  // Tipping - send a real tip to a celebrity, TikTok-gifting style.
  // See TippingService for how to connect a real payment provider.
  void _showCelebShareSheet(VideoItem video, int matchPercent) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF121212),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.ios_share, color: Colors.cyanAccent),
              title: const Text('Share', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                Share.share(
                  'Check out ${video.username} on Twins - a $matchPercent% celebrity look-alike!',
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.flag_outlined, color: Colors.redAccent),
              title: const Text(
                'Report',
                style: TextStyle(color: Colors.white),
              ),
              subtitle: const Text(
                'Flag this video for review',
                style: TextStyle(color: Colors.white38, fontSize: 11),
              ),
              onTap: () {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Thanks - our team will review this video.'),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showTipSheet(VideoItem video) {
    bool submitting = false;
    int? selectedAmount;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF121212),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          Future<void> confirmTip() async {
            if (selectedAmount == null) return;
            if (!authController.requireAccount(context)) return;
            setSheetState(() => submitting = true);
            final success = await TippingService.sendTip(
              celebrityId: video.id,
              amountUsd: selectedAmount!,
            );
            if (!sheetContext.mounted) return;
            setSheetState(() => submitting = false);
            if (success) {
              setState(() => video.tipsReceivedUsd += selectedAmount!);
              Navigator.pop(sheetContext);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    PaymentConfig.isConfigured
                        ? 'Tipped \$${selectedAmount!} to ${video.username}!'
                        : 'Tip simulated (no payment provider connected yet) - \$${selectedAmount!} to ${video.username}.',
                  ),
                ),
              );
            } else {
              setSheetState(() {});
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Tip failed. Please try again.')),
              );
            }
          }

          return Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.card_giftcard, color: Colors.amberAccent),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Tip ${video.username}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const Text(
                  '100% of tips go straight to the creator.',
                  style: TextStyle(color: Colors.white38, fontSize: 12),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: TippingService.presetAmounts.map((amount) {
                    final selected = selectedAmount == amount;
                    return GestureDetector(
                      onTap: () => setSheetState(() => selectedAmount = amount),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: selected ? Colors.amber : Colors.black26,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: selected ? Colors.amber : Colors.white24,
                          ),
                        ),
                        child: Text(
                          '\$$amount',
                          style: TextStyle(
                            color: selected ? Colors.black : Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.amber,
                    ),
                    onPressed: (selectedAmount == null || submitting)
                        ? null
                        : confirmTip,
                    child: submitting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.black,
                            ),
                          )
                        : Text(
                            selectedAmount == null
                                ? 'Choose an amount'
                                : 'Send \$${selectedAmount!} tip',
                            style: const TextStyle(color: Colors.black),
                          ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _toggleLike(VideoItem video) {
    if (!authController.requireAccount(context)) return;
    setState(() {
      video.likedByMe = !video.likedByMe;
      video.likes += video.likedByMe ? 1 : -1;
    });
  }

  void _showCelebCommentsSheet(VideoItem video) {
    final commentController = TextEditingController();
    final localComments = <String>[
      'No way you look THIS much alike 😍',
      'The 96% match is unreal',
      'Twins app really found their twin!',
    ];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF121212),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => Padding(
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
                      icon: const Icon(Icons.send, color: Colors.cyanAccent),
                      tooltip: 'Post comment',
                      onPressed: () {
                        if (commentController.text.trim().isEmpty) return;
                        if (!authController.requireAccount(context)) return;
                        setModalState(() {
                          localComments.add(commentController.text.trim());
                        });
                        setState(() => video.comments++);
                        commentController.clear();
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showBecomeCelebritySheet() {
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
          Future<void> submit() async {
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
            setSheetState(() => submitting = true);
            final paid = await PaymentService.purchaseCelebritySubscription();
            setSheetState(() => submitting = false);
            if (!sheetContext.mounted) return;
            if (!paid) {
              setSheetState(() => error = 'Payment failed. Please try again.');
              return;
            }
            Navigator.pop(sheetContext);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  PaymentConfig.isConfigured
                      ? 'Welcome, celebrity! Your account is now verified.'
                      : 'Payment simulated (no provider connected yet) - celebrity account created for testing.',
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
                      Icon(Icons.verified, color: Colors.blueAccent),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Create a Celebrity Account',
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
                    'Celebrity accounts get the blue verified tick and their own dedicated feed for \$9.99/month.',
                    style: TextStyle(color: Colors.white70),
                  ),
                  if (authController.isGuest) ...[
                    const SizedBox(height: 16),
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
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.amber,
                      ),
                      onPressed: submitting ? null : submit,
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
                              'Pay & Create Celebrity Account - \$9.99',
                              style: TextStyle(color: Colors.black),
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

  @override
  Widget build(BuildContext context) {
    final videos = _celebVideos;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        toolbarHeight: 40,
        titleSpacing: 8,
        title: Row(
          children: const [
            Text(
              'Celebrities',
              style: TextStyle(color: Colors.white, fontSize: 15),
            ),
            SizedBox(width: 4),
            Icon(Icons.verified, color: Colors.blueAccent, size: 14),
          ],
        ),
        actions: [
          // Me - your own profile, reachable from the Celebrities page too.
          Tooltip(
            message: 'My profile',
            child: GestureDetector(
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
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: CircleAvatar(
                  radius: 13,
                  backgroundColor: const Color(0xFF0284C7),
                  child: Text(
                    authController.isGuest
                        ? '?'
                        : authController.currentUser!.username
                              .substring(0, 1)
                              .toUpperCase(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
          ),
          // Upload - post a video without leaving the Celebrities page.
          IconButton(
            icon: const Icon(
              Icons.add_circle_outline,
              color: Colors.amberAccent,
              size: 20,
            ),
            tooltip: 'Post a video',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            visualDensity: VisualDensity.compact,
            onPressed: () {
              if (!authController.requireAccount(context)) return;
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const UploadScreen()),
              );
            },
          ),
          TextButton.icon(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              minimumSize: const Size(0, 30),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: _showBecomeCelebritySheet,
            icon: const Icon(Icons.add, color: Colors.amber, size: 14),
            label: const Text(
              'Become a Celebrity',
              style: TextStyle(color: Colors.amber, fontSize: 10),
            ),
          ),
        ],
        bottom: _selectedCelebCategory == 'All'
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(20),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black45,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.amber, width: 1),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _celebCategoryIcon(_selectedCelebCategory),
                            color: Colors.amberAccent,
                            size: 10,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'Watching: $_selectedCelebCategory celebrities',
                            style: const TextStyle(
                              color: Colors.amberAccent,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
      ),
      body: Column(
        children: [
          // Top Celebrities leaderboard - a horizontal "who's hot" strip,
          // ranked by followers, shown regardless of the category filter.
          if (_topCelebrities.isNotEmpty)
            Container(
              height: 72,
              margin: const EdgeInsets.only(top: 4),
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: _topCelebrities.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, i) {
                  final celeb = _topCelebrities[i];
                  final rank = i + 1;
                  return Tooltip(
                    message:
                        '#$rank ${celeb.username} - ${_formatCount(celeb.followers)} followers',
                    child: GestureDetector(
                      onTap: () {
                        final idx = _celebVideos.indexWhere(
                          (v) => v.id == celeb.id,
                        );
                        if (idx != -1 && _pageController.hasClients) {
                          _pageController.jumpToPage(idx);
                        }
                      },
                      child: Column(
                        children: [
                          Stack(
                            clipBehavior: Clip.none,
                            children: [
                              CircleAvatar(
                                radius: 18,
                                backgroundColor: const Color(0xFF0284C7),
                                backgroundImage:
                                    celeb.creatorAvatarUrl.isNotEmpty
                                    ? NetworkImage(celeb.creatorAvatarUrl)
                                    : null,
                                child: celeb.creatorAvatarUrl.isEmpty
                                    ? const Icon(
                                        Icons.person,
                                        color: Colors.white,
                                        size: 17,
                                      )
                                    : null,
                              ),
                              Positioned(
                                top: -3,
                                left: -3,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                    vertical: 1,
                                  ),
                                  decoration: BoxDecoration(
                                    gradient: const LinearGradient(
                                      colors: [Colors.amber, Colors.deepOrange],
                                    ),
                                    borderRadius: BorderRadius.circular(7),
                                  ),
                                  child: Text(
                                    '#$rank',
                                    style: const TextStyle(
                                      color: Colors.black,
                                      fontSize: 7,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          SizedBox(
                            width: 54,
                            child: Text(
                              celeb.username,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 8,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          Text(
                            _formatCount(celeb.followers),
                            style: const TextStyle(
                              color: Colors.amberAccent,
                              fontSize: 7,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),

          Expanded(
            child: videos.isEmpty
                ? Center(
                    child: Text(
                      'No $_selectedCelebCategory celebrities yet',
                      style: const TextStyle(color: Colors.white38),
                    ),
                  )
                : PageView.builder(
                    controller: _pageController,
                    scrollDirection: Axis.vertical,
                    itemCount: videos.length,
                    itemBuilder: (context, index) {
                      final video = videos[index];
                      // Real (or demo-fallback) match % - see
                      // MatchingApiService for how to connect a real backend.
                      final matchPercent = _matchPercentFor(video);

                      return Stack(
                        fit: StackFit.expand,
                        children: [
                          Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  Colors.purple.shade900,
                                  Colors.indigo.shade900,
                                  Colors.black,
                                ],
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                              ),
                            ),
                            child: video.mediaUrl != null
                                ? _FeedVideoPlayer(
                                    mediaUrl: video.mediaUrl!,
                                    filter: video.filter,
                                    isLiked: video.likedByMe,
                                    onDoubleTapLike: () {
                                      if (!video.likedByMe) _toggleLike(video);
                                    },
                                  )
                                : const Center(
                                    child: Icon(
                                      Icons.play_circle_outline,
                                      size: 80,
                                      color: Colors.white30,
                                    ),
                                  ),
                          ),

                          // Trending rank badge - top left
                          Positioned(
                            top: 16,
                            left: 16,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(
                                  colors: [Colors.amber, Colors.deepOrange],
                                ),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                '🔥 #${index + 1} Trending Celebrity',
                                style: const TextStyle(
                                  color: Colors.black,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),

                          // Match % badge - top right
                          Positioned(
                            top: 16,
                            right: 16,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(color: Colors.cyanAccent),
                              ),
                              child: Text(
                                '$matchPercent% Look-alike',
                                style: const TextStyle(
                                  color: Colors.cyanAccent,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),

                          // Caption + stats - bottom left
                          Positioned(
                            left: 16,
                            right: 90,
                            bottom: 28,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      video.username,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 15,
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    const Icon(
                                      Icons.verified,
                                      color: Colors.blueAccent,
                                      size: 15,
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '${_formatCount(video.followers)} followers  •  ${_formatCount(video.accountLikes)} likes',
                                  style: const TextStyle(
                                    color: Colors.amberAccent,
                                    fontSize: 11,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  video.caption,
                                  style: const TextStyle(color: Colors.white70),
                                ),
                              ],
                            ),
                          ),

                          // Engagement rail - follow / like / comment / share / message
                          Positioned(
                            right: 12,
                            bottom: 24,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // Creator's avatar with a follow badge - the exact
                                // same pattern as the For You page, for full
                                // feature parity.
                                GestureDetector(
                                  onTap: () => _showCelebProfileSheet(video),
                                  child: Stack(
                                    clipBehavior: Clip.none,
                                    children: [
                                      CircleAvatar(
                                        radius: 20,
                                        backgroundColor: const Color(
                                          0xFF0284C7,
                                        ),
                                        backgroundImage:
                                            video.creatorAvatarUrl.isNotEmpty
                                            ? NetworkImage(
                                                video.creatorAvatarUrl,
                                              )
                                            : null,
                                        child: video.creatorAvatarUrl.isEmpty
                                            ? const Icon(
                                                Icons.person,
                                                color: Colors.white,
                                                size: 20,
                                              )
                                            : null,
                                      ),
                                      Positioned(
                                        bottom: -6,
                                        left: 12,
                                        child: GestureDetector(
                                          onTap: () => _toggleFollow(video),
                                          child: Tooltip(
                                            message: video.isFollowedByMe
                                                ? 'Following - tap to unfollow'
                                                : 'Follow ${video.username}',
                                            child: Container(
                                              width: 18,
                                              height: 18,
                                              decoration: BoxDecoration(
                                                shape: BoxShape.circle,
                                                color: video.isFollowedByMe
                                                    ? Colors.green
                                                    : Colors.cyanAccent,
                                                border: Border.all(
                                                  color: const Color(
                                                    0xFF000000,
                                                  ),
                                                  width: 2,
                                                ),
                                              ),
                                              child: Icon(
                                                video.isFollowedByMe
                                                    ? Icons.check
                                                    : Icons.electrical_services,
                                                size: 11,
                                                color: Colors.black,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 14),
                                IconButton(
                                  icon: Icon(
                                    video.likedByMe
                                        ? Icons.favorite
                                        : Icons.favorite_border,
                                    color: Colors.redAccent,
                                    size: 24,
                                  ),
                                  tooltip: video.likedByMe ? 'Unlike' : 'Like',
                                  onPressed: () => _toggleLike(video),
                                ),
                                Text(
                                  '${video.likes}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                IconButton(
                                  icon: const Icon(
                                    Icons.chat_bubble_outline,
                                    color: Colors.white,
                                    size: 22,
                                  ),
                                  tooltip: 'Comments',
                                  onPressed: () =>
                                      _showCelebCommentsSheet(video),
                                ),
                                Text(
                                  '${video.comments}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                IconButton(
                                  icon: const Icon(
                                    Icons.mail_outline,
                                    color: Colors.white,
                                    size: 22,
                                  ),
                                  tooltip: 'Message',
                                  onPressed: () {
                                    if (!authController.requireAccount(
                                      context,
                                    )) {
                                      return;
                                    }
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            MessageScreen(video: video),
                                      ),
                                    );
                                  },
                                ),
                                const SizedBox(height: 6),
                                IconButton(
                                  icon: const Icon(
                                    Icons.share,
                                    color: Colors.white,
                                    size: 22,
                                  ),
                                  tooltip: 'Share',
                                  onPressed: () =>
                                      _showCelebShareSheet(video, matchPercent),
                                ),
                                const SizedBox(height: 6),
                                IconButton(
                                  icon: const Icon(
                                    Icons.card_giftcard,
                                    color: Colors.amberAccent,
                                    size: 22,
                                  ),
                                  tooltip: 'Send a tip',
                                  onPressed: () => _showTipSheet(video),
                                ),
                                if (video.tipsReceivedUsd > 0)
                                  Text(
                                    '\$${video.tipsReceivedUsd}',
                                    style: const TextStyle(
                                      color: Colors.amberAccent,
                                      fontSize: 10,
                                    ),
                                  ),
                              ],
                            ),
                          ),

                          // Scrollable category wheel - scroll to browse, tap to
                          // actually apply a filter. Rendered LAST (on top of
                          // everything else) and given real clearance from the
                          // top badges so it's never hidden behind other UI.
                          Positioned(
                            right: 12,
                            top: 56,
                            child: SizedBox(
                              height: 95,
                              width: 58,
                              child: ListWheelScrollView.useDelegate(
                                controller: _celebCategoryWheelController,
                                itemExtent: 28,
                                perspective: 0.006,
                                diameterRatio: 1.2,
                                physics: const FixedExtentScrollPhysics(),
                                onSelectedItemChanged: (i) {
                                  setState(
                                    () => _highlightedCelebCategoryIndex = i,
                                  );
                                },
                                childDelegate: ListWheelChildBuilderDelegate(
                                  childCount: _celebCategories.length,
                                  builder: (context, catIndex) {
                                    final isCentered =
                                        catIndex ==
                                        _highlightedCelebCategoryIndex;
                                    final isApplied =
                                        _celebCategories[catIndex] ==
                                        _selectedCelebCategory;
                                    return GestureDetector(
                                      onTap: () =>
                                          _applyCelebCategory(catIndex),
                                      child: Container(
                                        alignment: Alignment.center,
                                        decoration: BoxDecoration(
                                          color: isCentered
                                              ? Colors.amber.withValues(
                                                  alpha: 0.3,
                                                )
                                              : Colors.black38,
                                          borderRadius: BorderRadius.circular(
                                            7,
                                          ),
                                          border: Border.all(
                                            color: isCentered
                                                ? Colors.amber
                                                : Colors.transparent,
                                          ),
                                        ),
                                        child: Stack(
                                          alignment: Alignment.center,
                                          children: [
                                            Text(
                                              _celebCategories[catIndex],
                                              style: TextStyle(
                                                color: isCentered
                                                    ? Colors.amberAccent
                                                    : Colors.white60,
                                                fontSize: 8,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                            if (isApplied)
                                              const Positioned(
                                                top: 2,
                                                right: 2,
                                                child: Icon(
                                                  Icons.circle,
                                                  size: 5,
                                                  color: Colors.cyanAccent,
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  String _formatCount(int count) {
    if (count >= 1000000) return '${(count / 1000000).toStringAsFixed(1)}M';
    if (count >= 1000) return '${(count / 1000).toStringAsFixed(1)}K';
    return '$count';
  }
}

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  List<String> get _allUsers =>
      videoFeedStore.videos.map((v) => v.username).toSet().toList();
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
      backgroundColor: const Color(0xFF000000),
      appBar: AppBar(
        backgroundColor: const Color(0xFF000000),
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
              itemBuilder: (context, i) {
                final isCeleb = videoFeedStore.videos.any(
                  (v) => v.username == _results[i] && v.isCelebrity,
                );
                return ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Colors.blueGrey,
                    child: Icon(Icons.person),
                  ),
                  title: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _results[i],
                        style: const TextStyle(color: Colors.white),
                      ),
                      if (isCeleb) ...[
                        const SizedBox(width: 4),
                        const Icon(
                          Icons.verified,
                          color: Colors.blueAccent,
                          size: 14,
                        ),
                      ],
                    ],
                  ),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ProfileScreen(username: _results[i]),
                      ),
                    );
                  },
                );
              },
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

  // Your own posted videos - tap the trash icon on any of them to delete
  // it for good (with a confirmation first).
  Widget _uploadsGrid(List<VideoItem> videos) {
    if (videos.isEmpty) {
      return Center(
        child: Text(
          'Nothing here yet',
          style: TextStyle(color: Colors.white.withValues(alpha: 0.4)),
        ),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(4),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
      ),
      itemCount: videos.length,
      itemBuilder: (context, i) {
        final video = videos[i];
        return Stack(
          fit: StackFit.expand,
          children: [
            Container(
              color: Colors.blueGrey.shade900,
              child: const Icon(Icons.videocam, color: Colors.white24),
            ),
            Positioned(
              top: 4,
              right: 4,
              child: Tooltip(
                message: 'Delete this video',
                child: GestureDetector(
                  onTap: () => _confirmDeleteVideo(video),
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(
                      color: Colors.black87,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.delete_outline,
                      color: Colors.redAccent,
                      size: 16,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _confirmDeleteVideo(VideoItem video) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF121212),
        title: const Text(
          'Delete video?',
          style: TextStyle(color: Colors.white),
        ),
        content: Text(
          'This removes "${video.caption}" for good. This can\'t be undone.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text(
              'Cancel',
              style: TextStyle(color: Colors.white54),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () {
              videoFeedStore.videos.remove(video);
              videoFeedStore.notifyListeners();
              Navigator.pop(dialogContext);
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('Video deleted.')));
            },
            child: const Text('Delete'),
          ),
        ],
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
      backgroundColor: const Color(0xFF000000),
      appBar: AppBar(
        backgroundColor: const Color(0xFF000000),
        title: Text(
          widget.username,
          style: const TextStyle(color: Colors.white),
        ),
        actions: [
          if (!authController.isGuest &&
              widget.username == authController.currentUser!.username) ...[
            IconButton(
              icon: const Icon(Icons.settings, color: Colors.white70),
              tooltip: 'Settings',
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                );
              },
            ),
            IconButton(
              icon: const Icon(Icons.logout, color: Colors.white70),
              tooltip: 'Sign out',
              onPressed: () {
                authController.signOut();
                Navigator.pop(context);
              },
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Tooltip(
              message: 'Change profile picture',
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
                _uploadsGrid(myVideos),
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
// ---------------------------------------------------------------------------
// SETTINGS SCREEN
// ---------------------------------------------------------------------------
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _privateAccount = false;
  bool _pushNotifications = true;
  bool _emailNotifications = false;
  bool _autoplayVideos = true;
  bool _dataSaver = false;

  void _comingSoon(String feature) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$feature - coming soon once a backend is connected.'),
      ),
    );
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
      child: Text(
        title,
        style: const TextStyle(
          color: Colors.cyanAccent,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final me = authController.currentUser;
    return Scaffold(
      backgroundColor: const Color(0xFF000000),
      appBar: AppBar(
        backgroundColor: const Color(0xFF000000),
        title: const Text('Settings', style: TextStyle(color: Colors.white)),
      ),
      body: ListView(
        children: [
          _sectionHeader('Account'),
          ListTile(
            leading: const Icon(Icons.person_outline, color: Colors.white70),
            title: const Text(
              'Edit profile',
              style: TextStyle(color: Colors.white),
            ),
            subtitle: Text(
              me?.username ?? '',
              style: const TextStyle(color: Colors.white38),
            ),
            trailing: const Icon(Icons.chevron_right, color: Colors.white38),
            onTap: () => _comingSoon('Editing profile details'),
          ),
          ListTile(
            leading: const Icon(Icons.email_outlined, color: Colors.white70),
            title: const Text(
              'Change email',
              style: TextStyle(color: Colors.white),
            ),
            subtitle: Text(
              me?.email ?? '',
              style: const TextStyle(color: Colors.white38),
            ),
            trailing: const Icon(Icons.chevron_right, color: Colors.white38),
            onTap: () => _comingSoon('Changing email'),
          ),
          ListTile(
            leading: const Icon(Icons.lock_outline, color: Colors.white70),
            title: const Text(
              'Change password',
              style: TextStyle(color: Colors.white),
            ),
            trailing: const Icon(Icons.chevron_right, color: Colors.white38),
            onTap: () => _comingSoon('Changing password'),
          ),
          SwitchListTile(
            secondary: const Icon(
              Icons.lock_person_outlined,
              color: Colors.white70,
            ),
            title: const Text(
              'Private account',
              style: TextStyle(color: Colors.white),
            ),
            subtitle: const Text(
              'Only approved followers can see your videos',
              style: TextStyle(color: Colors.white38),
            ),
            activeThumbColor: Colors.cyanAccent,
            value: _privateAccount,
            onChanged: (v) => setState(() => _privateAccount = v),
          ),

          _sectionHeader('Notifications'),
          SwitchListTile(
            secondary: const Icon(
              Icons.notifications_outlined,
              color: Colors.white70,
            ),
            title: const Text(
              'Push notifications',
              style: TextStyle(color: Colors.white),
            ),
            activeThumbColor: Colors.cyanAccent,
            value: _pushNotifications,
            onChanged: (v) => setState(() => _pushNotifications = v),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.mail_outline, color: Colors.white70),
            title: const Text(
              'Email notifications',
              style: TextStyle(color: Colors.white),
            ),
            activeThumbColor: Colors.cyanAccent,
            value: _emailNotifications,
            onChanged: (v) => setState(() => _emailNotifications = v),
          ),

          _sectionHeader('Playback & Data'),
          SwitchListTile(
            secondary: const Icon(
              Icons.play_circle_outline,
              color: Colors.white70,
            ),
            title: const Text(
              'Autoplay videos',
              style: TextStyle(color: Colors.white),
            ),
            activeThumbColor: Colors.cyanAccent,
            value: _autoplayVideos,
            onChanged: (v) => setState(() => _autoplayVideos = v),
          ),
          SwitchListTile(
            secondary: const Icon(
              Icons.data_saver_on_outlined,
              color: Colors.white70,
            ),
            title: const Text(
              'Data saver',
              style: TextStyle(color: Colors.white),
            ),
            subtitle: const Text(
              'Lower video quality on mobile data',
              style: TextStyle(color: Colors.white38),
            ),
            activeThumbColor: Colors.cyanAccent,
            value: _dataSaver,
            onChanged: (v) => setState(() => _dataSaver = v),
          ),

          _sectionHeader('Privacy & Safety'),
          ListTile(
            leading: const Icon(Icons.block, color: Colors.white70),
            title: const Text(
              'Blocked accounts',
              style: TextStyle(color: Colors.white),
            ),
            trailing: const Icon(Icons.chevron_right, color: Colors.white38),
            onTap: () => _comingSoon('Blocked accounts'),
          ),
          ListTile(
            leading: const Icon(Icons.shield_outlined, color: Colors.white70),
            title: const Text(
              'Two-factor authentication',
              style: TextStyle(color: Colors.white),
            ),
            trailing: const Icon(Icons.chevron_right, color: Colors.white38),
            onTap: () => _comingSoon('Two-factor authentication'),
          ),

          _sectionHeader('Support'),
          ListTile(
            leading: const Icon(Icons.help_outline, color: Colors.white70),
            title: const Text(
              'Help center',
              style: TextStyle(color: Colors.white),
            ),
            trailing: const Icon(Icons.chevron_right, color: Colors.white38),
            onTap: () => _comingSoon('Help center'),
          ),
          ListTile(
            leading: const Icon(Icons.info_outline, color: Colors.white70),
            title: const Text(
              'About Twins',
              style: TextStyle(color: Colors.white),
            ),
            subtitle: const Text(
              'Version 1.0.0',
              style: TextStyle(color: Colors.white38),
            ),
            onTap: () => _comingSoon('About'),
          ),

          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.redAccent),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: () {
                  authController.signOut();
                  Navigator.popUntil(context, (route) => route.isFirst);
                },
                icon: const Icon(Icons.logout, color: Colors.redAccent),
                label: const Text(
                  'Sign out',
                  style: TextStyle(color: Colors.redAccent),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: Colors.red.shade900),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: _confirmDeleteAccount,
                icon: Icon(Icons.delete_forever, color: Colors.red.shade900),
                label: Text(
                  'Delete account',
                  style: TextStyle(color: Colors.red.shade900),
                ),
              ),
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  void _confirmDeleteAccount() {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF121212),
        title: const Text(
          'Delete your account?',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          'This permanently deletes your account and every video you\'ve posted. This cannot be undone.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text(
              'Cancel',
              style: TextStyle(color: Colors.white54),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red.shade900,
            ),
            onPressed: () {
              authController.deleteAccount();
              Navigator.pop(dialogContext);
              Navigator.popUntil(context, (route) => route.isFirst);
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('Account deleted.')));
            },
            child: const Text('Delete forever'),
          ),
        ],
      ),
    );
  }
}

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
  String _category = 'Dancing';

  final List<String> _filters = ['None', 'Warm', 'Cool', 'B&W', 'Vivid'];
  final List<String> _categoryOptions = [
    'Dancing',
    'Style',
    'Fashion',
    'Fitness',
    'Travel',
    'Comedy',
    'Acting',
    'Gospel',
  ];

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
  static const Duration kMaxVideoLength = Duration(minutes: 10);

  Future<void> _pickVideo(ImageSource source) async {
    final picker = ImagePicker();
    XFile? file;
    try {
      file = await picker.pickVideo(
        source: source,
        maxDuration: kMaxVideoLength,
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

      if (controller.value.duration > kMaxVideoLength) {
        await controller.dispose();
        if (!mounted) return;
        setState(() {
          _isLoadingVideo = false;
          _pickError =
              'That video is too long. Please choose one under 10 minutes.';
        });
        return;
      }

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
      final message = e.toString();
      final friendlyMessage =
          message.contains('MEDIA_ERR_SRC_NOT_SUPPORTED') ||
              message.contains('NotSupportedError') ||
              message.contains('format')
          ? "This video's format isn't supported by your browser. Try a different video, or re-save it as MP4 (H.264) first."
          : 'Could not load that video: $message';
      setState(() {
        _isLoadingVideo = false;
        _pickError = friendlyMessage;
      });
    }
  }

  void _showSourcePicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF121212),
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
            child: ColorFiltered(
              colorFilter: ColorFilter.matrix(
                kFilterMatrices[_filter] ?? kFilterMatrices['None']!,
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  VideoPlayer(_videoController!),
                  if (!_videoController!.value.isPlaying)
                    const Icon(
                      Icons.play_arrow,
                      size: 60,
                      color: Colors.white70,
                    ),
                ],
              ),
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
      backgroundColor: const Color(0xFF000000),
      appBar: AppBar(
        backgroundColor: const Color(0xFF000000),
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
                  category: _category,
                  likes: 0,
                  comments: 0,
                  creatorAvatarUrl: me.avatarUrl,
                  mediaUrl: _pickedFile!.path,
                  filter: _filter,
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
            if (_pickedFile == null)
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF0284C7),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onPressed: () => _pickVideo(ImageSource.camera),
                      icon: const Icon(Icons.videocam, color: Colors.white),
                      label: const Text('Record Video'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.cyanAccent),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onPressed: () => _pickVideo(ImageSource.gallery),
                      icon: const Icon(
                        Icons.video_library,
                        color: Colors.cyanAccent,
                      ),
                      label: const Text(
                        'From Gallery',
                        style: TextStyle(color: Colors.cyanAccent),
                      ),
                    ),
                  ),
                ],
              ),
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
                separatorBuilder: (_, __) => const SizedBox(width: 8),
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
              'Category',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Choose where this video shows up when people filter the feed.',
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 40,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _categoryOptions.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, i) {
                  final selected = _categoryOptions[i] == _category;
                  return ChoiceChip(
                    label: Text(_categoryOptions[i]),
                    selected: selected,
                    selectedColor: const Color(0xFF0284C7),
                    labelStyle: TextStyle(
                      color: selected ? Colors.white : Colors.white70,
                    ),
                    backgroundColor: Colors.black26,
                    onSelected: (_) =>
                        setState(() => _category = _categoryOptions[i]),
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
                      tooltip: 'Remove selected music',
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
                color: Color(0xFF121212),
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
