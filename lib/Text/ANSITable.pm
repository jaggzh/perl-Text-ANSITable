package Text::ANSITable;

use 5.010001;
use strict;
use warnings;
use Log::Any '$log';
use Moo;

#use List::Util 'first';
use Scalar::Util 'looks_like_number';
use Text::ANSI::Util 'ta_mbswidth_height';

# VERSION

has use_color => (
    is      => 'rw',
    default => sub {
        return $ENV{COLOR} if defined $ENV{COLOR};
        if (-t STDOUT) {
            # detect konsole, assume recent enough to support 24bit
            return 2**24 if $ENV{KONSOLE_DBUS_SERVICE}
                || $ENV{KONSOLE_DBUS_SESSION};
            if (($ENV{TERM} // "") =~ /256color/) {
                return 256;
            }
            return 16;
        } else {
            return 0;
        }
    },
);
has use_box_chars => (
    is      => 'rw',
    default => sub {
        $ENV{BOX_CHARS} // 1;
    },
);
has use_utf8 => (
    is      => 'rw',
    default => sub {
        $ENV{UTF8} //
            (($ENV{LANG} // "") =~ /utf-?8/i ? 1:undef) // 1;
    },
);
has columns => (
    is      => 'rw',
    default => sub { [] },
);
has rows => (
    is      => 'rw',
    default => sub { [] },
);
has _row_separators => ( # [index after which sep should be drawn, ...] sorted
    is      => 'rw',
    default => sub { [] },
);
has show_row_separator => (
    is      => 'rw',
    default => sub { 0 },
);
has _column_styles => ( # store per-column styles
    is      => 'rw',
    default => sub { [] },
);
has _row_styles => ( # store per-row styles
    is      => 'rw',
    default => sub { [] },
);
has _cell_styles => ( # store per-cell styles
    is      => 'rw',
    default => sub { [] },
);
has column_pad => (
    is      => 'rw',
    default => sub { 1 },
);
has column_lpad => (
    is      => 'rw',
);
has column_rlpad => (
    is      => 'rw',
);
has row_vpad => (
    is      => 'rw',
    default => sub { 0 },
);
has row_tpad => (
    is      => 'rw',
);
has row_bpad => (
    is      => 'rw',
);
has cell_fgcolor => (
    is => 'rw',
);
has cell_bgcolor => (
    is => 'rw',
);

sub BUILD {
    my ($self, $args) = @_;

    # pick a default border style
    unless ($self->{border_style}) {
        my $bs;
        if ($self->use_utf8) {
            $bs = 'bricko';
        } elsif ($self->use_box_chars) {
            $bs = 'single_boxchar';
        } else {
            $bs = 'single_ascii';
        }
        $self->border_style($bs);
    }

    # pick a default border style
    unless ($self->{color_theme}) {
        my $ct;
        if ($self->use_color) {
            if ($self->use_color >= 256) {
                $ct = 'default_256';
            } else {
                $ct = 'default_16';
            }
        } else {
            $ct = 'no_color';
        }
        $self->color_theme($ct);
    }
}

sub list_border_styles {
    require Module::List;
    require Module::Load;

    my ($self, $detail) = @_;
    state $all_bs;

    if (!$all_bs) {
        my $mods = Module::List::list_modules("Text::ANSITable::BorderStyle::",
                                              {list_modules=>1});
        no strict 'refs';
        $all_bs = {};
        for my $mod (sort keys %$mods) {
            $log->tracef("Loading border style module '%s' ...", $mod);
            Module::Load::load($mod);
            my $bs = \%{"$mod\::border_styles"};
            for (keys %$bs) {
                $bs->{$_}{name} = $_;
                $all_bs->{$_} = $bs->{$_};
            }
        }
    }

    if ($detail) {
        return $all_bs;
    } else {
        return sort keys %$all_bs;
    }
}

sub list_color_themes {
    require Module::List;
    require Module::Load;

    my ($self, $detail) = @_;
    state $all_ct;

    if (!$all_ct) {
        my $mods = Module::List::list_modules("Text::ANSITable::ColorTheme::",
                                              {list_modules=>1});
        no strict 'refs';
        $all_ct = {};
        for my $mod (sort keys %$mods) {
            $log->tracef("Loading color theme module '%s' ...", $mod);
            Module::Load::load($mod);
            my $ct = \%{"$mod\::color_themes"};
            for (keys %$ct) {
                $ct->{$_}{name} = $_;
                $all_ct->{$_} = $ct->{$_};
            }
        }
    }

    if ($detail) {
        return $all_ct;
    } else {
        return sort keys %$all_ct;
    }
}

sub border_style {
    my $self = shift;

    if (!@_) { return $self->{border_style} }
    my $bs = shift;

    if (!ref($bs)) {
        my $all_bs = $self->list_border_styles(1);
        $all_bs->{$bs} or die "Unknown border style name '$bs'";
        $bs = $all_bs->{$bs};
    }

    my $err;
    if ($bs->{box_chars} && !$self->use_box_chars) {
        $err = "use_box_chars is set to false";
    } elsif ($bs->{utf8} && !$self->use_utf8) {
        $err = "use_utf8 is set to false";
    }
    die "Can't select border style: $err" if $err;

    $self->{border_style} = $bs;
}

sub color_theme {
    my $self = shift;

    if (!@_) { return $self->{color_theme} }
    my $ct = shift;

    if (!ref($ct)) {
        my $all_ct = $self->list_color_themes(1);
        $all_ct->{$ct} or die "Unknown color theme name '$ct'";
        $ct = $all_ct->{$ct};
    }

    my $err;
    if (!$ct->{no_color} && !$self->use_color) {
        $err = "use_color is set to false";
    } elsif (!$ct->{no_color} && $ct->{256} &&
                 (!$self->use_color || $self->use_color < 256)) {
        $err = "use_color is not set to 256 color";
    }
    die "Can't select color theme: $err" if $err;

    $self->{color_theme} = $ct;
}

sub add_row {
    my ($self, $row) = @_;
    die "Row must be arrayref" unless ref($row) eq 'ARRAY';
    push @{ $self->{rows} }, $row;
    $self;
}

sub add_row_separator {
    my ($self) = @_;
    my $idx = ~~@{$self->{rows}}-1;
    # ignore duplicate separators
    push @{ $self->{_row_separators} }, $idx
        unless @{ $self->{_row_separators} } &&
            $self->{_row_separators}[-1] == $idx;
    $self;
}

sub add_rows {
    my ($self, $rows) = @_;
    die "Rows must be arrayref" unless ref($rows) eq 'ARRAY';
    $self->add_row($_) for @$rows;
    $self;
}

sub _colidx {
    my $self = shift;
    my $colname = shift;

    return $colname if looks_like_number($colname);
    my $cols = $self->{columns};
    for my $i (0..@$cols-1) {
        return $i if $cols->[$i] eq $colname;
    }
    die "Unknown column name '$colname'";
}

sub cell {
    my $self    = shift;
    my $row_num = shift;
    my $col     = shift;

    $col = $self->_colidx($col);

    if (@_) {
        my $oldval = $self->{rows}[$row_num][$col];
        $self->{rows}[$row_num][$col] = shift;
        return $oldval;
    } else {
        return $self->{rows}[$row_num][$col];
    }
}

sub column_style {
    my $self  = shift;
    my $col   = shift;
    my $style = shift;

    $col = $self->_colidx($col);

    if (@_) {
        my $oldval = $self->{_column_styles}[$col]{$style};
        $self->{_column_styles}[$col]{$style} = shift;
        return $oldval;
    } else {
        return $self->{_column_styles}[$col]{$style};
    }
}

sub row_style {
    my $self  = shift;
    my $row   = shift;
    my $style = shift;

    if (@_) {
        my $oldval = $self->{_row_styles}[$row]{$style};
        $self->{_row_styles}[$row]{$style} = shift;
        return $oldval;
    } else {
        return $self->{_row_styles}[$row]{$style};
    }
}

sub cell_style {
    my $self  = shift;
    my $row   = shift;
    my $col   = shift;
    my $style = shift;

    $col = $self->_colidx($col);

    if (@_) {
        my $oldval = $self->{_cell_styles}[$row][$col]{$style};
        $self->{_cell_styles}[$row][$col]{$style} = shift;
        return $oldval;
    } else {
        return $self->{_cell_styles}[$row][$col]{$style};
    }
}

sub draw {
    my ($self) = @_;

    my ($i, $j);

    # determine each column's width
    my @cwidths;
    my @hwidths; # header's widths
    my $hheight = 0;
    $i = 0;
    for my $c (@{ $self->{columns} }) {
        my $wh = ta_mbswidth_height($c);
        my $w = $wh->[0];
        $w = 0 if $w < 0;
        $cwidths[$i] = $hwidths[$i] = $w;
        my $h = $wh->[1];
        $hheight = $h if $hheight < $h;
        $i++;
    }
    $j = 0;
    my @dwidths;  # data row's widths ([row][col])
    my @dheights; # data row's heights
    for my $r (@{ $self->{rows} }) {
        $i = 0;
        for my $c (@$r) {
            next unless defined($c);
            my $wh = ta_mbswidth_height($c);
            my $w = $wh->[0];
            $dwidths[$j][$i] = $w;
            $cwidths[$i] = $w if $cwidths[$i] < $w;
            my $h = $wh->[1];
            if (defined $dheights[$j]) {
                $dheights[$j] = $h if $dheights[$j] > $h;
            } else {
                $dheights[$j] = $h;
            }
            $i++;
        }
        $j++;
    }

    my $bs = $self->{border_style};
    my $ch = $bs->{chars};

    my $bb = $bs->{box_chars} ? "\e(0" : "";
    my $ab = $bs->{box_chars} ? "\e(B" : "";
    my $cols = $self->{columns};

    my @t;

    # draw top border
    push @t, $bb, $ch->[0][0];
    $i = 0;
    for my $c (@$cols) {
        push @t, $ch->[0][1] x $cwidths[$i];
        $i++;
        push @t, $i == @$cols ? $ch->[0][3] : $ch->[0][2];
    }
    push @t, $ab, "\n";

    # draw header
    push @t, $bb, $ch->[1][0], $ab;
    $i = 0;
    for my $c (@$cols) {
        push @t, $c, (" " x ($cwidths[$i] - $hwidths[$i]));
        $i++;
        push @t, $bb, ($i == @$cols ? $ch->[1][2] : $ch->[1][1]), $ab;
    }
    push @t, "\n";

    # draw header-data separator
    push @t, $bb, $ch->[2][0];
    $i = 0;
    for my $c (@$cols) {
        push @t, $ch->[2][1] x $cwidths[$i];
        $i++;
        push @t, $i == @$cols ? $ch->[2][3] : $ch->[2][2];
    }
    push @t, $ab, "\n";

    # draw data rows
    $j = 0;
    for my $r0 (@{$self->{rows}}) {
        my @r = @$r0;
        $r[@cwidths-1] = undef if @r < @cwidths; # pad with undefs

        # draw data row
        push @t, $bb, $ch->[3][0], $ab;
        $i = 0;
        for my $c (@r) {
            $c //= ''; $dwidths[$j][$i] //= 0;
            push @t, $c, (" " x ($cwidths[$i] - $dwidths[$j][$i]));
            $i++;
            push @t, $bb, ($i == @$cols ? $ch->[3][2] : $ch->[3][1]), $ab;
        }
        push @t, "\n";

        # draw separator between data rows
        if ($self->{show_row_separator} && $j < @{$self->{rows}}-1) {
            push @t, $bb, $ch->[4][0];
            $i = 0;
            for my $c (@$cols) {
                push @t, $ch->[4][1] x $cwidths[$i];
                $i++;
                push @t, $i == @$cols ? $ch->[4][3] : $ch->[4][2];
            }
            push @t, $ab, "\n";
        }

        $j++;
    }

    # draw bottom border
    push @t, $bb, $ch->[5][0];
    $i = 0;
    for my $c (@$cols) {
        push @t, $ch->[5][1] x $cwidths[$i];
        $i++;
        push @t, $i == @$cols ? $ch->[5][3] : $ch->[5][2];
    }
    push @t, $ab;

    #use Data::Dump; dd \@t;
    join "", @t;
}

1;
#ABSTRACT: Create a nice formatted table using extended ASCII and ANSI colors

=for Pod::Coverage ^(BUILD)$

=head1 SYNOPSIS

 use 5.010;
 use Text::ANSITable;

 # don't forget this if you want to output utf8 characters
 binmode(STDOUT, ":utf8");

 my $t = Text::ANSITable->new;

 # set styles
 $t->border_style('bold_utf8');  # if not, it picks a nice default for you
 $t->color_theme('default_256'); # if not, it picks a nice default for you

 # fill data
 $t->columns(["name", "color", "price"]);
 $t->add_row(["chiki"      , "yellow",  2000]);
 $t->add_row(["lays"       , "green" ,  7000]);
 $t->add_row(["tao kae noi", "blue"  , 18500]);
 my $color = $t->cell(2, 1); # => "blue"
 $t->cell(2, 1, "red");

 # draw it!
 say $t->draw;


=head1 DESCRIPTION

This module is yet another text table formatter module like L<Text::ASCIITable>
or L<Text::SimpleTable>, with the following differences:

=over

=item * Colors and color themes

ANSI color codes will be used by default, but will degrade to black and white if
terminal does not support them.

=item * Box-drawing characters

Box-drawing characters will be used by default, but will degrade to using normal
ASCII characters if terminal does not support them.

=item * Unicode support

Columns containing wide characters stay aligned.

=back

Compared to Text::ASCIITable, it uses C<lower_case> method/attr names instead of
C<CamelCase>, and it uses arrayref for C<columns> and C<add_row>. When
specifying border styles, the order of characters are slightly different.

It uses L<Moo> object system.


=head1 BORDER STYLES

To list available border styles:

 say $_ for $t->list_border_styles;

Or you can also run the provided B<ansitable-list-border-styles> script.

Border styles are searched in C<Text::ANSITable::BorderStyle::*> modules
(asciibetically), in the C<%border_styles> variable. Hash keys are border style
names, hash values are border style specifications.

To choose border style, either set the C<border_style> attribute to an available
border style or a border specification directly.

 $t->border_style("singleh_boxchar");
 $t->border_style("foo");   # dies, no such border style
 $t->border_style({ ... }); # set specification directly

If no border style is selected explicitly, a nice default will be chosen. You
can also the C<ANSITABLE_BORDER_STYLE> environment variable to set the default.

To create a new border style, create a module under
C<Text::ANSITable::BorderStyle::>. Please see one of the existing border style
modules for example, like L<Text::ANSITable::BorderStyle::Default>. Format for
the C<chars> specification key:

 [
   [A, b, C, D],
   [E, F, G],
   [H, i, J, K],
   [L, M, N],
   [O, p, Q, R],
   [S, t, U, V],
 ]

 AbbbCbbbD        Top border characters
 E   F   G        Vertical separators for header row
 HiiiJiiiK        Separator between header row and first data row
 L   M   N        Vertical separators for data row
 OpppQpppR        Separator between data rows
 L   M   N
 StttUtttV        Bottom border characters

Each character must have visual width of 1. If A is an empty string, the top
border line will not be drawn. If H is an empty string, the header-data
separator line will not be drawn. If O is an empty string, data separator lines
will not be drawn. If S is an empty string, bottom border line will not be
drawn.


=head1 COLOR THEMES

To list available color themes:

 say $_ for $t->list_color_themes;

Or you can also run the provided B<ansitable-list-color-themes> script.

Color themes are searched in C<Text::ANSITable::ColorTheme::*> modules
(asciibetically), in the C<%color_themes> variable. Hash keys are color theme
names, hash values are color theme specifications.

To choose a color theme, either set the C<color_theme> attribute to an available
color theme or a border specification directly.

 $t->color_theme("default_256");
 $t->color_theme("foo");    # dies, no such color theme
 $t->color_theme({ ... });  # set specification directly

If no color theme is selected explicitly, a nice default will be chosen. You can
also the C<ANSITABLE_COLOR_THEME> environment variable to set the default.

To create a new color theme, create a module under
C<Text::ANSITable::ColorTheme::>. Please see one of the existing color theme
modules for example, like L<Text::ANSITable::ColorTheme::Default>.


=head1 COLUMN WIDTHS

By default column width is set just so it is enough to show the widest data.
Also by default terminal width is respected, so columns are shrunk
proportionally to fit terminal width.

You can set certain column's width using the C<column_style()> method, e.g.:

 $t->column_style('colname', width => 20);

You can also use negative number here to mean I<minimum> width.


=head1 CELL (HORIZONTAL) PADDING

By default cell (horizontal) padding is 1. This can be customized in the
following ways (in order of precedence, from lowest):

=over

=item * Setting C<column_pad> attribute

This sets left and right padding for all columns.

=item * Setting C<column_lpad> and C<column_rpad> attributes

They set left and right padding, respectively.

=item * Setting per-column padding using C<column_style()> method

Example:

 $t->column_style('colname', pad => 2);

=item * Setting per-column left/right padding using C<column_style()> method

 $t->column_style('colname', lpad => 0);
 $t->column_style('colname', lpad => 1);

=back


=head1 COLUMN VERTICAL PADDING

Default vertical padding is 0. This can be changed in the following ways (in
order of precedence, from lowest):

=over

=item * Setting C<row_vpad> attribute

This sets top and bottom padding.

=item * Setting C<row_tpad>/<row_bpad> attribute

They set top/bottom padding separately.

=item * Setting per-row vertical padding using C<row_style()>/C<add_row(s)> method

Example:

 $t->row_style($rownum, vpad => 1);

When adding row:

 $t->add_row($rownum, {vpad=>1});

=item * Setting per-row vertical padding using C<row_style()>/C<add_row(s)> method

Example:

 $t->row_style($rownum, tpad => 1);
 $t->row_style($rownum, bpad => 2);

When adding row:

 $t->add_row($row, {tpad=>1, bpad=>2});

=back


=head1 CELL COLORS

By default data format colors are used, e.g. cyan/green for text (using the
default color scheme). In absense of that, default_fgcolor and default_bgcolor
from the color scheme are used. You can customize colors in the following ways
(ordered by precedence, from lowest):

=item C<cell_fgcolor> and C<cell_bgcolor> attributes

Sets all cells' colors. Color should be specified using 6-hexdigit RGB which
will be converted to the appropriate terminal color.

Can also be set to a coderef which will receive ($rownum, $colname) and should
return an RGB color.

=item Per-column color using C<column_style()> method

Example:

 $t->column_style('colname', fgcolor => 'fa8888');
 $t->column_style('colname', bgcolor => '202020');

=item Per-row color using C<row_style()> method

Example:

 $t->row_style($rownum, fgcolor => 'fa8888');
 $t->row_style($rownum, bgcolor => '202020');

When adding row/rows:

 $t->add_row($row, {fgcolor=>..., bgcolor=>...});
 $t->add_rows($rows, {bgcolor=>...});

=item Per-cell color using C<cell_style()> method

Example:

 $t->cell_style($rownum, $colname, fgcolor => 'fa8888');
 $t->cell_style($rownum, $colname, bgcolor => '202020');


=head1 CELL (HORIZONTAL AND VERTICAL) ALIGNMENT

By default colors are added according to data formats, e.g. right align for
numbers, left for strings, and middle for bools. To customize it, use the
following ways (ordered by precedence, from lowest):

=over

=item * Setting per-column alignment using C<column_style()> method

Example:

 $t->column_style($colname, align  => 'middle'); # or left, or right
 $t->column_style($colname, valign => 'top');    # or bottom, or middle

=item * Setting per-cell alignment using C<cell_style()> method

 $t->cell_style($rownum, $colname, align  => 'middle');
 $t->cell_style($rownum, $colname, valign => 'top');

=back


=head1 COLUMN WRAPPING

By default column wrapping is turned on. You can set it on/off via the
C<column_wrap> attribute or per-column C<wrap> style.

Note that cell content past the column width will be clipped/truncated.


=head1 CELL FORMATS

The formats settings regulates how the data is formatted. The value for this
setting will be passed to L<Data::Unixish::Apply>'s apply(), as the C<functions>
argument. So it should be a single string (like C<date>) or an array (like C<<
['date', ['centerpad', {width=>20}]] >>).

See L<Data::Unixish> or install L<App::dux> and then run C<dux -l> to see what
functions are available. Functions of interest to formatting data include: bool,
num, sprintf, sprintfn, wrap, (among others).


=head1 ATTRIBUTES

=head2 rows => ARRAY OF ARRAY OF STR

Store row data.

=head2 columns => ARRAY OF STR

Store column names.

=head2 use_color => BOOL

Whether to output color. Default is taken from C<COLOR> environment variable, or
detected via C<(-t STDOUT)>. If C<use_color> is set to 0, an attempt to use a
colored color theme (i.e. anything that is not C<no_color>) will result in an
exception.

(In the future, setting C<use_color> to 0 might opt the module to use
normal/plain string routines instead of the slower ta_* functions from
L<Text::ANSI::Util>).

=head2 use_box_chars => BOOL

Whether to use box characters. Default is taken from C<BOX_CHARS> environment
variable, or 1. If C<use_box_chars> is set to 0, an attempt to use a border
style that uses box chararacters will result in an exception.

=head2 use_utf8 => BOOL

Whether to use box characters. Default is taken from C<UTF8> environment
variable, or detected via L<LANG> environment variable, or 1. If C<use_utf8> is
set to 0, an attempt to select a border style that uses Unicode characters will
result in an exception.

(In the future, setting C<use_utf8> to 0 might opt the module to use the
non-"mb_*" version of functions from L<Text::ANSI::Util>, e.g. ta_wrap() instead
of ta_mbwrap(), and so on).

=head2 border_style => HASH

Border style specification to use.

You can set this attribute's value with a specification or border style name.
See L<"/BORDER STYLES"> for more details.

=head2 color_theme => HASH

Color theme specification to use.

You can set this attribute's value with a specification or color theme name. See
L<"/COLOR THEMES"> for more details.

=head2 show_header => BOOL (default: 1)

When drawing, whether to show header.

=head2 show_row_separator => BOOL (default: 0)

When drawing, whether to show separator between rows.

=head2 column_pad => INT

Set (horizontal) padding for all columns. Can be overriden by per-column C<pad>
style.

=head2 column_lpad => INT

Set left padding for all columns. Overrides the C<column_pad> attribute. Can be
overriden by per-column <lpad> style.

=head2 column_rpad => INT

Set right padding for all columns. Overrides the C<column_pad> attribute. Can be
overriden by per-column <rpad> style.

=head2 row_vpad => INT

Set vertical padding for all rows. Can be overriden by per-row C<vpad> style.

=head2 row_tpad => INT

Set top padding for all rows. Overrides the C<row_vpad> attribute. Can be
overriden by per-row <tpad> style.

=head2 row_bpad => INT

Set bottom padding for all rows. Overrides the C<row_vpad> attribute. Can be
overriden by per-row <bpad> style.

=head2 cell_fgcolor => RGB|CODE

Set foreground color for all cells. Value should be 6-hexdigit RGB. Can also be
a coderef that will receive ($row_num, $colname) and should return an RGB color.
Can be overriden by per-cell C<fgcolor> style.

=head2 cell_bgcolor => RGB|CODE

Like C<cell_fgcolor> but for background color.


=head1 METHODS

=head2 $t = Text::ANSITable->new(%attrs) => OBJ

Constructor.

=head2 $t->list_border_styles => LIST

Return the names of available border styles. Border styles will be searched in
C<Text::ANSITable::BorderStyle::*> modules.

=head2 $t->add_row(\@row[, \%styles]) => OBJ

Add a row. Note that row data is not copied, only referenced.

Can also add per-row styles (which can also be done using C<row_style()>).

=head2 $t->add_rows(\@rows[, \%styles]) => OBJ

Add multiple rows. Note that row data is not copied, only referenced.

Can also add per-row styles (which can also be done using C<row_style()>).

=head2 $t->add_row_separator() => OBJ

Add a row separator line.

=head2 $t->cell($row_num, $col[, $newval]) => VAL

Get or set cell value at row #C<$row_num> (starts from zero) and column #C<$col>
(if C<$col> is a number, starts from zero) or column named C<$col> (if C<$col>
does not look like a number).

When setting value, old value is returned.

=head2 $t->column_style($col, $style[, $newval]) => VAL

Get or set per-column style for column named/numbered C<$col>. Available values
for C<$style>: pad, lpad, width, formats, fgcolor, bgcolor.

When setting value, old value is returned.

=head2 $t->row_style($row_num[, $newval]) => VAL

Get or set per-row style. Available values for C<$style>: vpad, tpad, bpad,
fgcolor, bgcolor.

When setting value, old value is returned.

=head2 $t->cell_style($row_num, $col[, $newval]) => VAL

Get or set per-cell style. Available values for C<$style>: formats, fgcolor,
bgcolor.

When setting value, old value is returned.

=head2 $t->draw => STR

Render table.


=head1 ENVIRONMENT

=head2 COLOR => BOOL

Can be used to set default value for the C<color> attribute.

=head2 BOX_CHARS => BOOL

Can be used to set default value for the C<box_chars> attribute.

=head2 UTF8 => BOOL

Can be used to set default value for the C<utf8> attribute.

=head2 ANSITABLE_BORDER_STYLE => STR

Can be used to set default value for C<border_style> attribute.

=head2 ANSITABLE_COLOR_THEME => STR

Can be used to set default value for C<border_style> attribute.


=head1 FAQ

=head2 I'm getting 'Wide character in print' error message when I use utf8 border styles!

Add something like this first before printing to your output:

 binmode(STDOUT, ":utf8");

=head2 My table looks garbled when viewed through pager like B<less>!

Try using C<-R> option of B<less> to see ANSI color codes. Try not using boxchar
border styles, use the utf8 or ascii version.

=head2 How to hide borders?

Choose border styles like C<space> or C<none>.

=head2 How do I format data?

Use the C<formats> per-column style or per-cell style. For example:

 $t->column_style('available', formats => [[bool=>{style=>'check_cross'}],
                                           [centerpad=>{width=>10}]]);
 $t->column_style('amount'   , formats => [[num=>{decimal_digits=>2}]]);
 $t->column_style('size'     , formats => [[num=>{style=>'kilo'}]]);


=head1 SEE ALSO

Other table-formatting modules: L<Text::Table>, L<Text::SimpleTable>,
L<Text::ASCIITable> (which I usually used), L<Text::UnicodeTable::Simple>,
L<Table::Simple> (uses Moose).

Modules used: L<Text::ANSI::Util>, L<Color::ANSI::Util>.

=cut
