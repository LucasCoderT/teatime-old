import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:draw/draw.dart';
import 'package:flutter/material.dart';
import 'package:flutter_custom_tabs/flutter_custom_tabs.dart';
import 'package:package_info/package_info.dart';
import 'package:path_provider/path_provider.dart';
import 'package:rxdart/rxdart.dart';
import 'package:teatime/items/post/detail.dart';
import 'package:teatime/models/account.dart';
import 'package:teatime/utils/draw_settings.dart';
import 'package:teatime/utils/enums.dart';
import 'package:teatime/utils/preferences.dart';
import 'package:teatime/utils/utils.dart';

final RegExp trendingExp = RegExp(".*(?=:):");
const int TIMEOUT = 5;
const String ERRORMESSAGE = "Unable to connect";
const List<String> subredditFields = [
  "icon_img",
  "name",
  "created",
  "created_utc",
  "community_icon",
  "header_img",
  "over18",
  "subscribers",
  "banner_background_image",
  "allow_images",
  "allow_videogifs",
  "allow_videos",
  "active_user_count"
];

final List<BottomScreens> loginRequiredScreens = [
  BottomScreens.post,
  BottomScreens.inbox,
  BottomScreens.profile
];

class RedditBloc {
  static final specialSubreddits = ["all", "popular"];
  final StreamController<String> onCode = new StreamController();
  final AppPreferences preferences;
  final defaultParams = {"g": "CA", "limit": "10"};
  final Map<String, Subreddit> loadedSubreddits = {};
  final List<String> history = [];
  List<Subreddit> trendingSubreddits = [];
  RedditCredentials credentials;
  PackageInfo packageInfo;
  ListingBloc listingBloc;
  Reddit reddit;

  Account get currentAccount => preferences.currentAccount;

  bool get isLoggedIn {
    if (currentAccount == null) {
      return false;
    }
    return currentAccount.anonymous == false;
  }

  final _snackBarSubject = PublishSubject<String>();

  Stream<String> get snackBarStream => _snackBarSubject.stream;

  String _snackBar;

  String get snackBar => _snackBar;

  set snackBar(String newSnackBar) {
    _snackBar = newSnackBar;
    _snackBarSubject.add(newSnackBar);
  }

  //-------------------------------

  final _currentSubredditSubject = PublishSubject<Subreddit>();

  Stream<Subreddit> get currentSubredditStream =>
      _currentSubredditSubject.stream;

  Subreddit _currentSubreddit;

  Subreddit get currentSubreddit => _currentSubreddit;

  set currentSubreddit(Subreddit newSubreddit) =>
      _currentSubredditSubject.add(newSubreddit);

  final _currentPositionSubject = PublishSubject<BottomScreens>();

  BottomScreens _currentPosition = BottomScreens.home;

  BottomScreens get currentPosition => _currentPosition;

  set currentPosition(BottomScreens newValue) {
    if (!isLoggedIn && loginRequiredScreens.contains(newValue)) {
      _snackBarSubject.add("Required to be Logged in");
    } else {
      _currentPositionSubject.add(newValue);
    }
  }

  final PublishSubject<bool> isBuiltSubject = PublishSubject<bool>();

  Stream<bool> get isBuiltStream => isBuiltSubject.stream;

  bool _isBuilt = false;

  bool get isBuilt => _isBuilt;

  set isBuilt(bool newisBuilt) => isBuiltSubject.add(newisBuilt);

  Stream<BottomScreens> get currentPositionStream =>
      _currentPositionSubject.stream;

  RedditBloc({@required this.preferences});

  Future<Null> initialize() async {
    try {
      isBuiltSubject.add(false);
      await loadSubreddits();
      packageInfo = await PackageInfo.fromPlatform();
      credentials = await RedditCredentials.buildRedditCredentials(packageInfo);
      listingBloc =
          ListingBloc(endpoint: "/", redditState: this, isSubreddit: true);
      if (preferences.currentAccountName != null) {
        await preferences.loadCurrentAccount();
        await createAuthReddit();
      } else {
        await createAnonReddit();
      }
      try {
        await currentAccount.load(state: reddit);
      } catch (e) {
        print("Unable to get subscriptions");
      }
      addListeners();
      if (reddit != null) isBuiltSubject.add(true);
    } catch (e) {}

  }

  void showSnackBar(String message) {
    _snackBarSubject.add(message);
  }

  Future<Null> createAuthReddit() async {
    var data = currentAccount?.authMap();
    if (data != null) {
      try {
        reddit = await Reddit.restoreAuthenticatedInstance(
          json.encode(data),
          userAgent: credentials.userAgent,
          clientId: credentials.clientId,
          redirectUri: credentials.redirectUri,
          clientSecret: credentials.clientSecret,
        ).timeout(Duration(seconds: TIMEOUT), onTimeout: () {
          if (!isBuiltSubject.isClosed) {
            isBuiltSubject.addError(DRAWAuthenticationError(ERRORMESSAGE));
          }
        });
      } catch (e) {
        isBuiltSubject.addError(e);
      }
    } else {
      await createAnonReddit();
    }
  }

  void addListeners() {
    preferences.currentSortStream.listen(updateBloc);
    preferences.currentRangeStream.listen(updateBloc);
    preferences.filterNSFWStream.listen(updateBloc);
    _currentPositionSubject.listen((screen) => _currentPosition = screen);
    _currentSubredditSubject
        .listen((subreddit) => _currentSubreddit = subreddit);
    isBuiltStream.listen((isBuilt) => _isBuilt = isBuilt);
  }

  void updateBloc(dynamic item) {
    listingBloc.load(refresh: true);
  }

  Future<Null> createAnonReddit() async {
    try {
      reddit = await Reddit.createUntrustedReadOnlyInstance(
              userAgent: credentials.userAgent,
              deviceId: preferences.uuid,
              clientId: credentials.clientId)
          .timeout(Duration(seconds: TIMEOUT), onTimeout: () {
        if (!isBuiltSubject.isClosed) {
          isBuiltSubject.addError(DRAWAuthenticationError(ERRORMESSAGE));
        }
      });
    } catch (e) {
      isBuiltSubject.addError(e);
    }
  }

  Future<Stream<String>> _listen(HttpServer server) async {
    server.listen((HttpRequest request) async {
      final String code = request.uri.queryParameters["code"];
      request.response
        ..statusCode = 200
        ..headers.set("Content-Type", ContentType.html.mimeType)
        ..write("<html><h1>You can now close this window</h1></html>");
      await request.response.close();
      onCode.add(code);
    });
    return onCode.stream;
  }

  Future<void> login(BuildContext context) async {
    HttpServer httpServer =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 4356);
    CustomTabsOption option = CustomTabsOption(
      toolbarColor: Theme.of(context).primaryColor,
      enableDefaultShare: false,
      enableUrlBarHiding: true,
      showPageTitle: false,
      animation: new CustomTabsAnimation.slideIn(),
    );
    try {
      Reddit authenticatedReddit = Reddit.createWebFlowInstance(
        redirectUri: credentials.redirectUri,
        clientSecret: credentials.clientSecret,
        clientId: credentials.clientId,
        userAgent: credentials.userAgent,
      );
      var authUrl = authenticatedReddit.auth
          .url(credentials.scopes, 'teatime', compactLogin: true);
      Stream<String> authCode = await _listen(httpServer);
      NavigatorState navigator = Navigator.of(context);
      await launch(authUrl.toString(), option: option);
      authCode.listen((code) async {
        if (code != null) {
          // If everything worked correctly, we should be able to retrieve
          // information about the authenticated account.
          await authenticatedReddit.auth.authorize(code).whenComplete(() async {
            reddit = authenticatedReddit;
            await preferences.signIn(state: authenticatedReddit);
            listingBloc.load(refresh: true);
            await onCode.close();
          }).whenComplete(() => httpServer.close());
        }
      }).onDone(() {
        httpServer.close();
        navigator.pop();
      });
    } catch (e) {
      httpServer.close();
    }
  }

  Subreddit getSub(String fullName) => loadedSubreddits[fullName];

  bool isCurrentSub(SubredditRef subreddit) => currentSubreddit == subreddit;

  Future<Null> changeSubreddit(
      BuildContext context, dynamic newSubreddit) async {
    var newEndpoint = newSubreddit;
    if (newSubreddit == null) {
      currentSubreddit = null;
      history.clear();
      listingBloc.endpoint = "/";
      return;
    }
    Navigator.popUntil(context, ModalRoute.withName("/"));
    currentPosition = BottomScreens.home;
    try {
      newSubreddit =
          reddit.subreddit(newSubreddit?.displayName ?? newSubreddit);
      await fetchSubreddit(newSubreddit);
      newEndpoint = newSubreddit?.path ?? newSubreddit;
      currentSubreddit = loadedSubreddits[newSubreddit.displayName];
    } catch (e) {}
    history.add(newEndpoint);
    listingBloc.endpoint = newEndpoint;
  }

  Future<Subreddit> fetchSubreddit(dynamic subreddit,
      {bool failSliently = false}) async {
    if (subreddit is SubredditRef) {
      try {
        Subreddit data = await subreddit.populate();
        if (data != null) {
          loadedSubreddits[data.displayName] = data;
          await cacheSubreddits();
        }
        return data;
      } on DRAWAuthenticationError {
        if (!specialSubreddits.contains(subreddit.displayName) && !failSliently)
          showSnackBar("Subreddit not found");
        return null;
      }
    } else {
      loadedSubreddits[subreddit?.displayName] = subreddit;
    }
    return loadedSubreddits[subreddit?.displayName];
  }

//  Future<Null> getRandomSubreddit(BuildContext context,
//      {bool nsfw: false}) async {
//    SubredditRef random = reddit.subreddit("random");
//    try {
//      await random.fetch();
//    } on DRAWRedirectResponse catch (e) {
//      RegExp exp = RegExp(r'(?<=\/r\/).*(?=\/)');
//      String subreddit = exp.firstMatch(e.path).group(0);
//      if (subreddit != null) {
//        await changeSubreddit(context, subreddit);
//      }
//    }
//  }

  Future<List<Subreddit>> getTrendingSubreddits() async {
    if (trendingSubreddits.isNotEmpty) {
      return trendingSubreddits;
    }
    var response = await reddit.get("r/trendingsubreddits");
    var data = response['listing'][0];
    var results = (data.title as String).replaceFirst(trendingExp, "");
    var trendingSubStrings = results.split(",");
    var subreddits = List<String>();
    for (var sub in trendingSubStrings) {
      subreddits.add(sub.trim());
    }
    for (var sub in subreddits) {
      SubredditRef ref = reddit.subreddit(sub.substring(3));
      var _data = await fetchSubreddit(ref, failSliently: true);
      if (_data != null) trendingSubreddits.add(_data);
    }
    return trendingSubreddits;
  }

  Future<Null> removeAccount(String accountName) async {
    await preferences.signOut(accountName);
    dispose();
    await initialize();
  }

  void goTo(BuildContext context,
      {dynamic target, bool pop = false, TargetType type, String heroKey}) {
    if (target is String && type == TargetType.User) {
      Navigator.pushNamed(context, "/u/$target");
    }
    if (target is RedditorRef || target is Redditor) {
      Navigator.pushNamed(context, "/u/${target?.displayName}");
    }
    if (target is SubredditRef || target is Subreddit) {
      if (isLoggedIn && preferences.isTracking) {
        currentAccount.clickSubreddit(target);
      }
      changeSubreddit(context, target);
    }
    if (pop) {
      Navigator.of(context).pop();
    }
  }

  void showShareMenu(BuildContext context, Uri content) {
    Dialogs.showMediaShare(context, content);
  }

  Future<Subreddit> loadSubreddit(SubredditRef subredditdata) async {
    if (!loadedSubreddits.containsKey(subredditdata.displayName)) {
      try {
        Subreddit subreddit = await subredditdata.populate();
        if (subreddit != null) {
          loadedSubreddits[subreddit.displayName] = subreddit;
          cacheSubreddits();
          return subreddit;
        }
      } catch (e) {
        print("Error loading subreddit: ${subredditdata.displayName}");
      }
    }
    return loadedSubreddits[subredditdata.displayName];
  }

  void goBackSubreddit(String newCurrent) {
    for (MapEntry<String, Subreddit> data in loadedSubreddits.entries) {
      if (data.value.path == newCurrent) {
        _currentSubredditSubject.add(data.value);
      }
    }
    if (newCurrent == "/") _currentSubreddit = null;
    listingBloc.endpoint = newCurrent;
  }

  void manageHistory() {
    var previousSub = history.removeLast();
    if (history.isEmpty) {
      goBackSubreddit("/");
    } else {
      goBackSubreddit(previousSub);
    }
  }

  Future<File> _getFile() async {
    Directory appDocDir = await getApplicationDocumentsDirectory();
    String appDocPath = appDocDir.path;
    File fileData = File("$appDocPath/subreddits.json");
    return fileData;
  }

  Future<Null> cacheSubreddits() async {
    File fileData = await _getFile();
    Map<String, dynamic> data = {};
    for (Subreddit sub in loadedSubreddits.values) {
      data[sub.displayName] = {};
      sub.data.forEach((key, value) => subredditFields.contains(key)
          ? data[sub.displayName][key] = value
          : null);
    }
    String jsonData = json.encode(data);
    fileData.writeAsString(jsonData);
  }

  Future<Null> loadSubreddits() async {
    try {
      File fileData = await _getFile();
      Map<String, dynamic> data = json.decode(await fileData.readAsString());
      data.forEach((String name, dynamic data) {
        loadedSubreddits[name] = Subreddit.parse(reddit, data);
      });
    } catch (e) {}
  }

  Future<Null> logout() async {
    await preferences.signOut(preferences.currentAccountName);
    await preferences.save();
    initialize();
  }

  Future<Null> switchAccount(String newAccount) async {
    preferences.currentAccountName = newAccount;
    await initialize();
  }

  void dispose() {
    listingBloc.dispose();
    history.clear();
    reddit = null;
    credentials = null;
    listingBloc = null;
    _currentPosition = BottomScreens.home;
    _currentSubreddit = null;
  }

  Future<Null> refreshSubreddit() async {
    if (currentSubreddit != null) {
      listingBloc.loadedData.clear();
      if (currentSubreddit != null) {
        Subreddit newSubreddit = await currentSubreddit.refresh();
        cacheSubreddits();
        _currentSubredditSubject.add(newSubreddit);
      }
      listingBloc.load(refresh: true);
    }
  }

  Future<Null> clickPost(BuildContext context, Submission post) async {
    preferences.clickPost(post);
    Navigator.push(
        context,
        MaterialPageRoute(
            builder: (context) => PostDetail(
                  post: post,
                )));
  }
}
