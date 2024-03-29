import 'dart:async';

import 'package:flutter/material.dart';
import 'package:teatime/screens/general/loading_screen.dart';
import 'package:teatime/screens/general/retry.dart';
import 'package:teatime/utils/listingBloc.dart';
import 'package:draw/draw.dart';

typedef ListingWidgetBuilder<T> = Widget Function(
    BuildContext context, ListingSnapShot<T> item);

class ListingSnapShot<T> {
  final T data;

  final int index;

  bool get hasData => data != null;

  ListingSnapShot(this.data, this.index);
}

class ListingBuilder<T> extends StatefulWidget {
  final ListingBloc listingBloc;
  final ListingWidgetBuilder<T> builder;
  final SliverAppBar sliverAppBar;
  final Widget loading;
  final Widget empty;
  final Widget Function(Exception error) error;
  final bool refresh;

  const ListingBuilder({
    Key key,
    @required this.builder,
    @required this.listingBloc,
    @required this.sliverAppBar,
    this.loading,
    this.empty,
    this.error,
    this.refresh = true,
  }) : super(key: key);

  @override
  _ListingState createState() => _ListingState();
}

class _ListingState extends State<ListingBuilder> {
  final ScrollController _scrollController = ScrollController();
  ListingBloc listingBloc;

  @override
  void initState() {
    super.initState();
    listingBloc = widget.listingBloc;
    _scrollController.addListener(_onScroll);
    if (widget.refresh) {
      listingBloc.load();
    } else if (listingBloc.loadedData.isEmpty) {
      listingBloc.load();
    }
    listingBloc.jumpToTopStream
        .listen((bool data) => data == true ? jumpToTop() : null);
  }

  @override
  void dispose() {
    super.dispose();
    _scrollController.removeListener(_onScroll);
    if (widget.refresh) listingBloc.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.extentAfter < 30 && !listingBloc.isLoading)
      listingBloc.load();
  }

  void jumpToTop() {
    try {
      _scrollController.position
          .jumpTo(_scrollController.position.minScrollExtent + 5);
    } catch (e) {}
  }

  List<Widget> buildSlivers() {
    List<Widget> slivers = [];
    if (widget.sliverAppBar != null) {
      slivers.add(widget.sliverAppBar);
    }
    slivers.add(SliverList(
        delegate: SliverChildBuilderDelegate((context, index) {
      var item = listingBloc.loadedData.keys.toList()[index];
      return widget.builder(
          context, ListingSnapShot(listingBloc.loadedData[item], index));
    }, childCount: listingBloc.loadedData.length)));
    return slivers;
  }

  Widget buildScaffold() {
    return Scaffold(
      body: LoadingScreen(),
    );
  }

  Widget onError(Exception error) {
    switch (error.runtimeType) {
      case DRAWAuthenticationError:
        return Center(child: Text("Unable to process request"));
      case TimeoutException:
        return RetryWidget(
          message: Text("Request timed out"),
          onTap: () => listingBloc.load(refresh: true),
        );
      case DRAWInternalError:
        return RetryWidget(
          message: Text((error as DRAWInternalError).message),
        );
      default:
        if (widget.error != null) {
          return widget.error(error);
        } else {
          return RetryWidget(
            message: Text(error.toString()),
            onTap: () => listingBloc.load(refresh: true),
          );
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    return new StreamBuilder(
      stream: listingBloc.resultsStream,
      initialData: false,
      builder: (BuildContext context, AsyncSnapshot<bool> snapshot) {
        if (snapshot.hasError) {
          onError(snapshot.error);
        }
        if (listingBloc.loadedData.isNotEmpty) {
          return RefreshIndicator(
            onRefresh: () => widget.listingBloc.load(refresh: true),
            child: Scrollbar(
              child: CustomScrollView(
                controller: _scrollController,
                slivers: buildSlivers(),
              ),
            ),
          );
        } else if (snapshot.data == false) {
          return widget.loading ?? LoadingScreen();
        } else if (snapshot.data == null) {
          return widget.empty ??
              RetryWidget(
                  onTap: () => widget.listingBloc.load(
                        refresh: true,
                      ));
        } else {
          return CustomScrollView(
            slivers: <Widget>[widget.sliverAppBar],
          );
        }
      },
    );
  }
}
