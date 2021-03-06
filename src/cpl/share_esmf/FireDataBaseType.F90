module FireDataBaseType

#include "shr_assert.h"

  !-----------------------------------------------------------------------
  ! !DESCRIPTION:
  ! module for handling of fire data
  !
  ! !USES:
  use ESMF
  use dshr_strdata_mod , only : shr_strdata_type 
  use shr_kind_mod     , only : r8 => shr_kind_r8, CL => shr_kind_CL
  use shr_log_mod      , only : errMsg => shr_log_errMsg
  use clm_varctl       , only : iulog
  use spmdMod          , only : masterproc, mpicom, iam
  use abortutils       , only : endrun
  use decompMod        , only : bounds_type
  use FireMethodType   , only : fire_method_type
  !
  implicit none
  private
  !
  ! !PUBLIC TYPES:
  public :: fire_base_type
  !
  type, abstract, extends(fire_method_type) :: fire_base_type
    private
      ! !PRIVATE MEMBER DATA:
      real(r8), public, pointer :: forc_hdm(:)  ! Human population density
      type(shr_strdata_type)    :: sdat_hdm     ! Human population density input data stream
      real(r8), public, pointer :: forc_lnfm(:) ! Lightning frequency
      type(shr_strdata_type)    :: sdat_lnfm    ! Lightning frequency input data stream
    contains
      !
      ! !PUBLIC MEMBER FUNCTIONS:
      procedure, public :: FireInit => BaseFireInit ! Initialization of Fire
      procedure, public :: BaseFireInit             ! Initialization of Fire
      procedure, public :: FireInterp               ! Interpolate fire data
      procedure(FireReadNML_interface), public, deferred :: &
           FireReadNML                              ! Read in namelist for Fire
      procedure(need_lightning_and_popdens_interface), public, deferred :: &
           need_lightning_and_popdens               ! Returns true if need lightning & popdens
      !
      ! !PRIVATE MEMBER FUNCTIONS:
      procedure, private :: hdm_init    ! position datasets for dynamic human population density
      procedure, private :: hdm_interp  ! interpolates between two years of human pop. density file data
      procedure, private :: lnfm_init   ! position datasets for Lightning
      procedure, private :: lnfm_interp ! interpolates between two years of Lightning file data
  end type fire_base_type

  abstract interface
     !-----------------------------------------------------------------------
     function need_lightning_and_popdens_interface(this) result(need_lightning_and_popdens)
       !
       ! !DESCRIPTION:
       ! Returns true if need lightning and popdens, false otherwise
       !
       ! USES
       import :: fire_base_type
       !
       ! !ARGUMENTS:
       class(fire_base_type), intent(in) :: this
       logical :: need_lightning_and_popdens  ! function result
       !-----------------------------------------------------------------------
     end function need_lightning_and_popdens_interface
  end interface

  character(len=*), parameter, private :: sourcefile = &
       __FILE__

!==============================================================================
contains
!==============================================================================

  subroutine FireReadNML_interface( this, NLFilename )
    !
    ! !DESCRIPTION:
    ! Read the namelist for Fire
    !
    ! !USES:
    !
    ! !ARGUMENTS:
    class(fire_base_type) :: this
    character(len=*), intent(in) :: NLFilename ! Namelist filename
  end subroutine FireReadNML_interface

  !================================================================
  subroutine BaseFireInit( this, bounds, NLFilename )
    !
    ! !DESCRIPTION:
    ! Initialize CN Fire module
    ! !USES:
    use shr_infnan_mod  , only : nan => shr_infnan_nan, assignment(=)
    !
    ! !ARGUMENTS:
    class(fire_base_type) :: this
    type(bounds_type), intent(in) :: bounds
    character(len=*),  intent(in) :: NLFilename
    !-----------------------------------------------------------------------

    if ( this%need_lightning_and_popdens() ) then
       ! Allocate lightning forcing data
       allocate( this%forc_lnfm(bounds%begg:bounds%endg) )
       this%forc_lnfm(bounds%begg:) = nan
       ! Allocate pop dens forcing data
       allocate( this%forc_hdm(bounds%begg:bounds%endg) )
       this%forc_hdm(bounds%begg:) = nan

       call this%hdm_init(bounds, NLFilename)
       call this%hdm_interp(bounds)
       call this%lnfm_init(bounds, NLFilename)
       call this%lnfm_interp(bounds)
    end if

  end subroutine BaseFireInit

  !================================================================
  subroutine FireInterp(this,bounds)
    !
    ! !DESCRIPTION:
    ! Interpolate CN Fire datasets
    !
    ! !ARGUMENTS:
    class(fire_base_type) :: this
    type(bounds_type), intent(in) :: bounds
    !-----------------------------------------------------------------------

    if ( this%need_lightning_and_popdens() ) then
       call this%hdm_interp(bounds)
       call this%lnfm_interp(bounds)
    end if

  end subroutine FireInterp

  !================================================================
  subroutine hdm_init( this, bounds, NLFilename )
   !
   ! !DESCRIPTION:
   ! Initialize data stream information for population density.
   !
   ! !USES:
   use clm_nlUtilsMod   , only : find_nlgroup_name
   use histFileMod      , only : hist_addfld1d
   use lnd_comp_shr     , only : mesh, model_clock
   use dshr_strdata_mod , only : shr_strdata_init_from_inline
   use shr_mpi_mod      , only : shr_mpi_bcast
   !
   ! !ARGUMENTS:
   implicit none
   class(fire_base_type)         :: this
   type(bounds_type), intent(in) :: bounds
   character(len=*),  intent(in) :: NLFilename   ! Namelist filename
   !
   ! !LOCAL VARIABLES:
   integer            :: nu_nml                        ! unit for namelist file
   integer            :: nml_error                     ! namelist i/o error flag
   integer            :: stream_year_first_popdens     ! first year in pop. dens. stream to use
   integer            :: stream_year_last_popdens      ! last year in pop. dens. stream to use
   integer            :: model_year_align_popdens      ! align stream_year_first_hdm with
   character(len=CL)  :: stream_fldFileName_popdens    ! population density streams filename
   character(len=CL)  :: stream_meshfile_popdens       ! population density streams filename
   character(len=CL)  :: popdensmapalgo                ! mapping alogrithm for population density
   character(len=CL)  :: popdens_tintalgo              ! time interpolation alogrithm for population density
   integer            :: rc
   character(*), parameter :: subName = "('hdmdyn_init')"
   !-----------------------------------------------------------------------

   namelist /popd_streams/          &
        stream_year_first_popdens,  &
        stream_year_last_popdens,   &
        model_year_align_popdens,   &
        popdensmapalgo,             &
        stream_fldFileName_popdens, &
        stream_meshfile_popdens,    &
        popdens_tintalgo

   ! Default values for namelist
   stream_year_first_popdens  = 1       ! first year in stream to use
   stream_year_last_popdens   = 1       ! last  year in stream to use
   model_year_align_popdens   = 1       ! align stream_year_first_popdens with this model year
   stream_fldFileName_popdens = ' '
   stream_meshfile_popdens    = ' '
   popdens_tintalgo           = 'nearest'
   popdensmapalgo             = 'bilinear'

   ! Read popd_streams namelist
   if (masterproc) then
      open( newunit=nu_nml, file=trim(NLFilename), status='old', iostat=nml_error )
      call find_nlgroup_name(nu_nml, 'popd_streams', status=nml_error)
      if (nml_error == 0) then
         read(nu_nml, nml=popd_streams,iostat=nml_error)
         if (nml_error /= 0) then
            call endrun(msg='ERROR reading popd_streams namelist'//errMsg(sourcefile, __LINE__))
         end if
      end if
      close(nu_nml)
   endif

   call shr_mpi_bcast(stream_year_first_popdens  , mpicom)
   call shr_mpi_bcast(stream_year_last_popdens   , mpicom)
   call shr_mpi_bcast(model_year_align_popdens   , mpicom)
   call shr_mpi_bcast(stream_fldFileName_popdens , mpicom)
   call shr_mpi_bcast(stream_meshfile_popdens    , mpicom)
   call shr_mpi_bcast(popdens_tintalgo           , mpicom)

   if (masterproc) then
      write(iulog,'(a)'   ) ' '
      write(iulog,'(a)'   ) 'popdens_streams settings:'
      write(iulog,'(a,i8)') '  stream_year_first_popdens  = ',stream_year_first_popdens
      write(iulog,'(a,i8)') '  stream_year_last_popdens   = ',stream_year_last_popdens
      write(iulog,'(a,i8)') '  model_year_align_popdens   = ',model_year_align_popdens
      write(iulog,'(a,a)' ) '  stream_fldFileName_popdens = ',trim(stream_fldFileName_popdens)
      write(iulog,'(a,a)' ) '  stream_meshfile_popdens    = ',trim(stream_meshfile_popdens)
      write(iulog,'(a,a)' ) '  stream_varnames            = ','hdm'
      write(iulog,'(a,a)' ) '  time interp algo           = ',trim(popdens_tintalgo)
      write(iulog,'(a,a)' ) '  mapping interp algo        = ',trim(popdensmapalgo)
      write(iulog,'(a)'   ) ' '
   endif

    ! Initialize the cdeps data type sdat
    call shr_strdata_init_from_inline(this%sdat_hdm,                 &
         my_task             = iam,                                  &
         logunit             = iulog,                                &
         compname            = 'LND',                                &
         model_clock         = model_clock,                          &
         model_mesh          = mesh,                                 &
         stream_meshfile     = trim(stream_meshfile_popdens),        &
         stream_lev_dimname  = 'null',                               & 
         stream_mapalgo      = trim(popdensmapalgo),                 &
         stream_filenames    = (/trim(stream_fldfilename_popdens)/), &
         stream_fldlistFile  = (/'hdm'/),                            &
         stream_fldListModel = (/'hdm'/),                            &
         stream_yearFirst    = stream_year_first_popdens,            &
         stream_yearLast     = stream_year_last_popdens,             &
         stream_yearAlign    = model_year_align_popdens,             &
         stream_offset       = 0,                                    &
         stream_taxmode      = 'extend',                             &
         stream_dtlimit      = 1.0e30_r8,                            &
         stream_tintalgo     = popdens_tintalgo,                     &
         stream_name         = 'Population density data',            &
         rc                  = rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, line=__LINE__, file=__FILE__)) then
       call ESMF_Finalize(endflag=ESMF_END_ABORT)
    end if

   ! Add history fields
   call hist_addfld1d (fname='HDM', units='counts/km^2',      &
         avgflag='A', long_name='human population density',   &
         ptr_lnd=this%forc_hdm, default='inactive')

  end subroutine hdm_init

  !================================================================
  subroutine hdm_interp( this, bounds)
  !
  ! !DESCRIPTION:
  ! Interpolate data stream information for population density.
  !
  ! !USES:
    use clm_time_manager , only : get_curr_date
    use dshr_methods_mod , only : dshr_fldbun_getfldptr
    use dshr_strdata_mod , only : shr_strdata_advance
    !
    ! !ARGUMENTS:
    class(fire_base_type)       :: this
    type(bounds_type), intent(in) :: bounds
    !
    ! !LOCAL VARIABLES:
    integer :: g, ig
    integer :: year    ! year (0, ...) for nstep+1
    integer :: mon     ! month (1, ..., 12) for nstep+1
    integer :: day     ! day of month (1, ..., 31) for nstep+1
    integer :: sec     ! seconds into current date for nstep+1
    integer :: mcdate  ! Current model date (yyyymmdd)
    integer :: rc
    real(r8), pointer :: dataptr1d(:)
    !-----------------------------------------------------------------------

    ! Advance sdat stream
    call get_curr_date(year, mon, day, sec)
    mcdate = year*10000 + mon*100 + day
    call shr_strdata_advance(this%sdat_hdm, ymd=mcdate, tod=sec, logunit=iulog, istr='hdmdyn', rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, line=__LINE__, file=__FILE__)) then
       call ESMF_Finalize(endflag=ESMF_END_ABORT)
    end if

    ! Get pointer for stream data that is time and spatially interpolate to model time and grid
    call dshr_fldbun_getFldPtr(this%sdat_hdm%pstrm(1)%fldbun_model, 'hdm', fldptr1=dataptr1d, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, line=__LINE__, file=__FILE__)) then
       call ESMF_Finalize(endflag=ESMF_END_ABORT)
    end if

    ig = 0
    do g = bounds%begg,bounds%endg
       ig = ig+1
       this%forc_hdm(g) = dataptr1d(ig)
    end do

  end subroutine hdm_interp

  !================================================================
  subroutine lnfm_init( this, bounds, NLFilename )
  !
  ! !DESCRIPTION:
  !
  ! Initialize data stream information for Lightning.
  !
  ! !USES:
  use clm_nlUtilsMod   , only : find_nlgroup_name
  use lnd_comp_shr     , only : mesh, model_clock
  use dshr_strdata_mod , only : shr_strdata_init_from_inline
  use histFileMod      , only : hist_addfld1d
  use shr_mpi_mod      , only : shr_mpi_bcast
  !
  ! !ARGUMENTS:
  implicit none
  class(fire_base_type)       :: this
  type(bounds_type), intent(in) :: bounds
  character(len=*),  intent(in) :: NLFilename
  !
  ! !LOCAL VARIABLES:
  integer            :: nu_nml                     ! unit for namelist file
  integer            :: nml_error                  ! namelist i/o error flag
  integer            :: stream_year_first_lightng  ! first year in Lightning stream to use
  integer            :: stream_year_last_lightng   ! last year in Lightning stream to use
  integer            :: model_year_align_lightng   ! align stream_year_first_lnfm with
  character(len=CL)  :: stream_fldFileName_lightng ! lightning stream filename to read
  character(len=CL)  :: stream_meshfile_lightng    ! lightning stream filename to read
  character(len=CL)  :: lightng_tintalgo           ! stream -> model time interpolation alogrithm
  character(len=CL)  :: lightngmapalgo             ! stream-> model mapping alogrithm
  integer            :: rc
  character(*), parameter :: subName = "('lnfmdyn_init')"
  !-----------------------------------------------------------------------

   namelist /light_streams/         &
        stream_year_first_lightng,  &
        stream_year_last_lightng,   &
        model_year_align_lightng,   &
        lightngmapalgo,             &
        stream_fldFileName_lightng, &
        stream_meshfile_lightng,    &
        lightng_tintalgo

   ! Default values for namelist
    stream_year_first_lightng  = 1      ! first year in stream to use
    stream_year_last_lightng   = 1      ! last  year in stream to use
    model_year_align_lightng   = 1      ! align stream_year_first_lnfm with this model year
    stream_fldFileName_lightng = ' '
    stream_meshfile_lightng    = ' '
    lightng_tintalgo           = 'linear'
    lightngmapalgo             = 'bilinear'

   ! Read light_streams namelist
   if (masterproc) then
      open( newunit=nu_nml, file=trim(NLFilename), status='old', iostat=nml_error )
      call find_nlgroup_name(nu_nml, 'light_streams', status=nml_error)
      if (nml_error == 0) then
         read(nu_nml, nml=light_streams,iostat=nml_error)
         if (nml_error /= 0) then
            call endrun(msg='ERROR reading light_streams namelist'//errMsg(sourcefile, __LINE__))
         end if
      end if
      close(nu_nml)
   endif

   call shr_mpi_bcast(stream_year_first_lightng  , mpicom)
   call shr_mpi_bcast(stream_year_last_lightng   , mpicom)
   call shr_mpi_bcast(model_year_align_lightng   , mpicom)
   call shr_mpi_bcast(stream_fldFileName_lightng , mpicom)
   call shr_mpi_bcast(stream_meshfile_lightng    , mpicom)
   call shr_mpi_bcast(lightng_tintalgo           , mpicom)

   if (masterproc) then
      write(iulog,'(a)') ' '
      write(iulog,'(a)'   ) 'light_stream settings:'
      write(iulog,'(a,i8)') '  stream_year_first_lightng  = ',stream_year_first_lightng
      write(iulog,'(a,i8)') '  stream_year_last_lightng   = ',stream_year_last_lightng
      write(iulog,'(a,i8)') '  model_year_align_lightng   = ',model_year_align_lightng
      write(iulog,'(a,a)' ) '  stream_fldFileName_lightng = ',trim(stream_fldFileName_lightng)
      write(iulog,'(a,a)' ) '  stream_meshfile            = ',trim(stream_meshfile_lightng)
      write(iulog,'(a,a)' ) '  stream_varnames            = ','lnfm' 
      write(iulog,'(a,a)' ) '  time interp algo           = ',trim(lightng_tintalgo)
      write(iulog,'(a,a)' ) '  mapping interp algo        = ',trim(lightngmapalgo)
      write(iulog,'(a)') ' '
   endif

    ! Initialize the cdeps data type sdat
    call shr_strdata_init_from_inline(this%sdat_lnfm,                &
         my_task             = iam,                                  &
         logunit             = iulog,                                &
         compname            = 'LND',                                &
         model_clock         = model_clock,                          &
         model_mesh          = mesh,                                 &
         stream_meshfile     = trim(stream_meshfile_lightng),        &
         stream_lev_dimname  = 'null',                               & 
         stream_mapalgo      = trim(lightngmapalgo),                 &
         stream_filenames    = (/trim(stream_fldfilename_lightng)/), &
         stream_fldlistFile  = (/'lnfm'/),                           &
         stream_fldListModel = (/'lnfm'/),                           &
         stream_yearFirst    = stream_year_first_lightng,            &
         stream_yearLast     = stream_year_last_lightng,             &
         stream_yearAlign    = model_year_align_lightng,             &
         stream_offset       = 0,                                    &
         stream_taxmode      = 'cycle',                              &
         stream_dtlimit      = 1.5_r8,                               &
         stream_tintalgo     = lightng_tintalgo,                     &
         stream_name         = 'Lightning frequency data',           &
         rc                  = rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, line=__LINE__, file=__FILE__)) then
       call ESMF_Finalize(endflag=ESMF_END_ABORT)
    end if

   ! Add history fields
   call hist_addfld1d (fname='LNFM', units='counts/km^2/hr',  &
         avgflag='A', long_name='Lightning frequency',        &
         ptr_lnd=this%forc_lnfm, default='inactive')

  end subroutine lnfm_init

  !================================================================
  subroutine lnfm_interp(this, bounds )
    !
    ! !DESCRIPTION:
    ! Interpolate data stream information for Lightning.
    !
    ! !USES:
    use clm_time_manager , only : get_curr_date
    use dshr_methods_mod , only : dshr_fldbun_getfldptr
    use dshr_strdata_mod , only : shr_strdata_advance
    !
    ! !ARGUMENTS:
    class(fire_base_type)       :: this
    type(bounds_type), intent(in) :: bounds
    !
    ! !LOCAL VARIABLES:
    integer :: g, ig
    integer :: year    ! year (0, ...) for nstep+1
    integer :: mon     ! month (1, ..., 12) for nstep+1
    integer :: day     ! day of month (1, ..., 31) for nstep+1
    integer :: sec     ! seconds into current date for nstep+1
    integer :: mcdate  ! Current model date (yyyymmdd)
    integer :: rc
    real(r8), pointer :: dataptr1d(:)
    !-----------------------------------------------------------------------

    ! Advance sdat stream
    call get_curr_date(year, mon, day, sec)
    mcdate = year*10000 + mon*100 + day
    call shr_strdata_advance(this%sdat_lnfm, ymd=mcdate, tod=sec, logunit=iulog, istr='lnfmdyn', rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, line=__LINE__, file=__FILE__)) then
       call ESMF_Finalize(endflag=ESMF_END_ABORT)
    end if

    ! Get pointer for stream data that is time and spatially interpolate to model time and grid
    call dshr_fldbun_getFldPtr(this%sdat_lnfm%pstrm(1)%fldbun_model, 'lnfm', fldptr1=dataptr1d, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, line=__LINE__, file=__FILE__)) then
       call ESMF_Finalize(endflag=ESMF_END_ABORT)
    end if

    ig = 0
    do g = bounds%begg,bounds%endg
       ig = ig+1
       this%forc_lnfm(g) = dataptr1d(ig)
    end do

  end subroutine lnfm_interp

end module FireDataBaseType
