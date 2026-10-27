// Only the rows of a playlist's track list tell the index they laid out. The library's rows, the album page's
// and the list cells of Search and the artist page are left alone: the index belongs to playlists.
#import "Core/SGCore.h"
#import "AlphaIndex.h"

%hook _TtC35ListUXPlatform_FreeTierPlaylistImpl25ElementCollectionViewCell
- (void)layoutSubviews {
    %orig;
    SGAlphaIndexNoteRow((UIView *)self);
}
%end

// The letters only line up with an alphabetical list, so the page's sorting adapter is handed over for the
// index to put the list in Spotify's Title order while the switch is on.
%hook _TtC35ListUXPlatform_FreeTierPlaylistImpl21FTPSortingAdapterImpl
- (instancetype)init {
    id adapter = %orig;
    SGAlphaIndexNoteSortAdapter(adapter);
    return adapter;
}
%end

%ctor {
    if (!SGEnabled(SGKeyAlphaIndex)) return;
    %init;
    SGRequireClasses(@[@"_TtC35ListUXPlatform_FreeTierPlaylistImpl25ElementCollectionViewCell"]);
}
