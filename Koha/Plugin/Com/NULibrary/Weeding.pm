package Koha::Plugin::Com::NULibrary::Weeding;

## It's good practice to use Modern::Perl
use Modern::Perl;

## Required for all plugins
use base qw(Koha::Plugins::Base);

## We will also need to include any Koha libraries we want to access
use C4::Context;
use C4::Auth;
use C4::Koha;
use Koha::DateUtils;
use Koha::Libraries;
#use Koha::Patron::Categories;
use Koha::AuthorisedValues;
#use Koha::Account::Lines;
use MARC::Record;
use Cwd qw(abs_path);
use Mojo::JSON qw(decode_json);;
use URI::Escape qw(uri_unescape);
use LWP::UserAgent;
use Data::Dumper;

## Here we set our plugin version
our $VERSION = "v0.0.147";


## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name            => 'Weeding and Historical Charges Plugin',
    author          => 'Hannah Co',
    date_authored   => '2020-10-05',
    date_updated    => "2020-10-07",
    minimum_version => '20.05.00.000',
    maximum_version => undef,
    version         => $VERSION,
    description     => 'This plugin creates a custom report of item checkouts '
      . 'that can be narrowed by a variety of parameters.',
};

## This is the minimum code required for a plugin's 'new' method
## More can be added, but none should be removed
sub new {
    my ( $class, $args ) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);

    return $self;
}

## The existance of a 'report' subroutine means the plugin is capable
## of running a report. This example report can output a list of patrons
## either as HTML or as a CSV file. Technically, you could put all your code
## in the report method, but that would be a really poor way to write code
## for all but the simplest reports
sub report {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    unless ( $cgi->param('output') ) {
        $self->report_step1();
    }
    else {
        $self->report_step2();
    }
}

## If your plugin needs to add some CSS to the staff intranet, you'll want
## to return that CSS here. Don't forget to wrap your CSS in <style>
## tags. By not adding them automatically for you, you'll have a chance
## to include external CSS files as well!
sub intranet_head {
    my ( $self ) = @_;

    return q|
        <style>
        </style>
    |;
}

## If your plugin needs to add some javascript in the staff intranet, you'll want
## to return that javascript here. Don't forget to wrap your javascript in
## <script> tags. By not adding them automatically for you, you'll have a
## chance to include other javascript files if necessary.
sub intranet_js {
    my ( $self ) = @_;

}

## This method allows you to add new html elements to the catalogue toolbar.
## You'll want to return a string of raw html here, most likely a button or other
## toolbar element of some form. See bug 20968 for more details.
sub intranet_catalog_biblio_enhancements_toolbar_button {
    my ( $self ) = @_;

    return q|
        <a class="btn btn-default btn-sm">
          <i class="fa fa-hand-spock-o" aria-hidden="true"></i>
          Historical Charges Report
        </a>
    |;
}

## This is the 'install' method. Any database tables or other setup that should
## be done when the plugin if first installed should be executed in this method.
## The installation method should always return true if the installation succeeded
## or false if it failed.
sub install() {
    my ( $self, $args ) = @_;

}

## This is the 'upgrade' method. It will be triggered when a newer version of a
## plugin is installed over an existing older version of a plugin
sub upgrade {
    my ( $self, $args ) = @_;

    my $dt = dt_from_string();
    $self->store_data( { last_upgraded => $dt->ymd('-') . ' ' . $dt->hms(':') } );

    return 1;
}

## This method will be run just before the plugin files are deleted
## when a plugin is uninstalled. It is good practice to clean up
## after ourselves!
sub uninstall() {
    my ( $self, $args ) = @_;

}

## These are helper functions that are specific to this plugin
## You can manage the control flow of your plugin any
## way you wish, but I find this is a good approach
sub report_step1 {
  my ( $self, $args ) = @_;
  my $cgi = $self->{'cgi'};

  my $template = $self->get_template({ file => 'report-step1.tt' });
	my $av = ( category => 'ccode' );
  my $av2 = ( category => 'LOC' );

  my @libraries = Koha::Libraries->search;
  my @categories = Koha::Patron::Categories->search_limited({}, {order_by => ['description']});
	my @collections = C4::Koha::GetAuthorisedValues([$av]);
  my @locations = C4::Koha::GetAuthorisedValues([$av2]);
  $template->param(
      libraries => \@libraries,
      collections => \@collections,
      locations => \@locations,
  );

  $self->output_html( $template->output() );
}

sub report_step2 {
  my ( $self, $args ) = @_;
  my $cgi = $self->{'cgi'};

  my $dbh = C4::Context->dbh;

  my $branch = $cgi->param('branch');
  my $ccode = $cgi->param('ccode');
  my $location = $cgi->param('location');
  my $output = $cgi->param('output');

  my $callFrom   = $cgi->param('callFrom');
  my $callTo   = $cgi->param('callTo');
  my $copyrightYear  = $cgi->param('copyrightYear');
  my $maxcheckouts   = $cgi->param('maxcheckouts');
  my $recents        = $cgi->param('recentcheckouts');

  my $query = "
	SELECT items.homebranch AS homebranch, items.ccode AS collection, items.location AS location,items.itemcallnumber AS callnumber,items.enumchron,biblio.copyrightdate as copyrightyear,items.cn_sort AS cn_sort,items.cn_source,items.datelastborrowed AS lastcheckout,items.barcode,biblio.title AS title,biblio.author,items.issues AS checkouts,items.itemnotes_nonpublic as notes
	FROM items
	LEFT JOIN biblioitems ON (items.biblioitemnumber=biblioitems.biblioitemnumber)
	LEFT JOIN biblio ON (biblioitems.biblionumber=biblio.biblionumber)
  WHERE (items.homebranch = '$branch'
  ";

  unless ( $ccode eq '%' ) {
    $query .= "
  	  AND items.ccode = '$ccode'
  	";
  }

  unless ( $location eq '%' ) {
    $query .= "
  	  AND items.location = '$location'
  	";
  }

  $query .= ")";

  if ( $copyrightYear > 0 ) {
      $query .= "
          AND biblio.copyrightdate < '$copyrightYear'
      ";
  }

  unless ( $maxcheckouts eq undef ) {
      $query .= "
          AND items.issues <= '$maxcheckouts'
      ";
  }

  unless ( $mincheckouts eq undef ) {
      $query .= "
          AND items.issues >= '$mincheckouts'
      ";
  }

  unless ( $recentcheckouts eq undef ) {
      $query .= "
          AND items.datelastborrowed >= '$recentcheckouts'
      ";
  }

	if ( $callFrom ) {
		if ( $callTo ) {
#      my $callToLength = scalar($callTo);
#      my $callFromLength = scalar($callFrom);
		$query .= "
        AND SUBSTRING(items.cn_sort,1,2) BETWEEN '$callFrom' AND CONCAT('$callTo', 'ZZZ%')
		";
		} else {
        $query .= "
        AND items.cn_sort LIKE CONCAT('$callFrom', '%')
		";
		}
  }

	$query .= "
	ORDER BY items.cn_source, items.cn_sort, items.enumchron ASC
	";

  my $sth = $dbh->prepare($query);
  $sth->execute();

  my @results;
  while ( my $row = $sth->fetchrow_hashref() ) {
      push( @results, $row );
  }

  my $filename;
  if ( $output eq "csv" ) {
      print $cgi->header( -type=>'text', -attachment => 'Historical Usage Report.csv' );
      $filename = 'report-step2-csv.tt';
  }
  else {
      print $cgi->header();
      $filename = 'report-step2-html.tt';
  }

  my $template = $self->get_template({ file => $filename });

  $template->param(
      date_ran     => dt_from_string(),
      results_loop => \@results,
	    branch       => Koha::Libraries->find($branch)->branchname,
  );

  unless ( $ccode eq '%' ) {
      $template->param( ccode => $ccode );
  }
  unless ( $location eq '%' ) {
      $template->param( location => $location );
  }

  my $test = Dumper(\@results);
  $template->param( test => $test );

  print $template->output();
}

1;
