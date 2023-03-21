
!> Various definitions and tools for running an NGA2 simulation
module simulation
  use precision,         only: WP
  use geometry,          only: cfg
  use lpt_class,         only: lpt
  use hypre_uns_class,   only: hypre_uns
  use hypre_str_class,   only: hypre_str
  use lowmach_class,     only: lowmach
  use sgsmodel_class,    only: sgsmodel
  use timetracker_class, only: timetracker
  use ensight_class,     only: ensight
  use partmesh_class,    only: partmesh
  use event_class,       only: event
  use monitor_class,     only: monitor
  implicit none
  private
  
  !> Get an LPT solver, a lowmach solver, and corresponding time tracker, plus a couple of linear solvers
  type(hypre_uns),   public :: ps
  type(hypre_str),   public :: vs
  type(lowmach),     public :: fs
  type(lpt),         public :: lp
  type(sgsmodel),    public :: sgs
  type(timetracker), public :: time
  
  !> Ensight postprocessing
  type(partmesh) :: pmesh
  type(ensight)  :: ens_out
  type(event)    :: ens_evt
  
  !> Simulation monitor file
  type(monitor) :: mfile,cflfile,lptfile,tfile
  
  public :: simulation_init,simulation_run,simulation_final
  
  !> Work arrays and fluid properties
  real(WP), dimension(:,:,:,:), allocatable :: SR
  real(WP), dimension(:,:,:), allocatable :: resU,resV,resW
  real(WP), dimension(:,:,:), allocatable :: Ui,Vi,Wi,rho0,dRHOdt
  real(WP), dimension(:,:,:), allocatable :: srcUlp,srcVlp,srcWlp
  real(WP), dimension(:,:,:), allocatable :: tmp1,tmp2,tmp3
  real(WP) :: visc,rho,inlet_velocity

  !> Max timestep size for LPT
  real(WP) :: lp_dt,lp_dt_max
  
  !> Wallclock time for monitoring
  type :: timer
    real(WP) :: time_in
    real(WP) :: time
    real(WP) :: percent
  end type timer
  type(timer) :: wt_total,wt_vel,wt_pres,wt_lpt,wt_sgs,wt_rest

  !> Event for post-processing
  type(event) :: ppevt

contains

   !> Specialized subroutine that outputs the velocity distribution
   subroutine postproc_vel()
      use string,    only: str_medium
      use mpi_f08,   only: MPI_ALLREDUCE,MPI_SUM
      use parallel,  only: MPI_REAL_WP
      implicit none
      integer :: iunit,ierr,i,j,k
      real(WP), dimension(:,:), allocatable :: Uavg,Uavg_,vol,vol_
      character(len=str_medium) :: filename,timestamp
      ! Allocate vertical line storage
      allocate(Uavg (fs%cfg%imin:fs%cfg%imax,fs%cfg%jmin:fs%cfg%jmax)); Uavg =0.0_WP
      allocate(Uavg_(fs%cfg%imin:fs%cfg%imax,fs%cfg%jmin:fs%cfg%jmax)); Uavg_=0.0_WP
      allocate(vol_ (fs%cfg%imin:fs%cfg%imax,fs%cfg%jmin:fs%cfg%jmax)); vol_ =0.0_WP
      allocate(vol  (fs%cfg%imin:fs%cfg%imax,fs%cfg%jmin:fs%cfg%jmax)); vol  =0.0_WP
      ! Integrate all data over x and z
      do k=fs%cfg%kmin_,fs%cfg%kmax_
         do j=fs%cfg%jmin_,fs%cfg%jmax_
            do i=fs%cfg%imin_,fs%cfg%imax_
               vol_(i,j) = vol_(i,j)+fs%cfg%vol(i,j,k)*(1.0_WP-lp%VF(i,j,k))
               Uavg_(i,j)=Uavg_(i,j)+fs%cfg%vol(i,j,k)*(1.0_WP-lp%VF(i,j,k))*fs%U(i,j,k)
            end do
         end do
      end do
      ! All-reduce the data
      call MPI_ALLREDUCE( vol_, vol,fs%cfg%nx*fs%cfg%ny,MPI_REAL_WP,MPI_SUM,fs%cfg%comm,ierr)
      call MPI_ALLREDUCE(Uavg_,Uavg,fs%cfg%nx*fs%cfg%ny,MPI_REAL_WP,MPI_SUM,fs%cfg%comm,ierr)
      do j=fs%cfg%jmin,fs%cfg%jmax
         do i=fs%cfg%imin,fs%cfg%imax
            if (vol(i,j).gt.0.0_WP) then
               Uavg(i,j)=Uavg(i,j)/vol(i,j)
            else
               Uavg(i,j)=0.0_WP
            end if
         end do
      end do
      ! If root, print it out
      if (fs%cfg%amRoot) then
         filename='Uavg_'
         write(timestamp,'(es12.5)') time%t
         open(newunit=iunit,file=trim(adjustl(filename))//trim(adjustl(timestamp)),form='formatted',status='replace',access='stream',iostat=ierr)
         write(iunit,'(a12,3x,a12)') 'Height','Uavg'
         do j=fs%cfg%jmin,fs%cfg%jmax
            write(iunit,'(es12.5,3x,es12.5)') fs%cfg%ym(j),Uavg(100,j)
         end do
         close(iunit)
      end if
      ! Deallocate work arrays
      deallocate(Uavg,Uavg_,vol,vol_)
   end subroutine postproc_vel

  !> Function that localizes the left (x-) of the domain
   function left_of_domain(pg,i,j,k) result(isIn)
     use pgrid_class, only: pgrid
     implicit none
     class(pgrid), intent(in) :: pg
     integer, intent(in) :: i,j,k
     logical :: isIn
     isIn=.false.
     if (i.eq.pg%imin) isIn=.true.
   end function left_of_domain

   !> Function that localizes the right (x+) of the domain
   function right_of_domain(pg,i,j,k) result(isIn)
     use pgrid_class, only: pgrid
     implicit none
     class(pgrid), intent(in) :: pg
     integer, intent(in) :: i,j,k
     logical :: isIn
     isIn=.false.
     if (i.eq.pg%imax+1) isIn=.true.
   end function right_of_domain
  
   !> Function that localizes the bottom (y-) of the domain
   function bottom_of_domain(pg,i,j,k) result(isIn)
     use pgrid_class, only: pgrid
     implicit none
     class(pgrid), intent(in) :: pg
     integer, intent(in) :: i,j,k
     logical :: isIn
     isIn=.false.
     if (j.eq.pg%jmin) isIn=.true.
   end function bottom_of_domain

   !> Function that localizes the top (y+) of the domain
   function top_of_domain(pg,i,j,k) result(isIn)
     use pgrid_class, only: pgrid
     implicit none
     class(pgrid), intent(in) :: pg
     integer, intent(in) :: i,j,k
     logical :: isIn
     isIn=.false.
     if (j.eq.pg%jmax+1) isIn=.true.
   end function top_of_domain


  !> Initialization of problem solver
  subroutine simulation_init
    use param, only: param_read
    implicit none


    ! Initialize time tracker with 1 subiterations
    initialize_timetracker: block
      time=timetracker(amRoot=cfg%amRoot)
      call param_read('Max timestep size',time%dtmax)
      call param_read('Max time',time%tmax)
      call param_read('Max cfl number',time%cflmax)
      time%dt=time%dtmax
      time%itmax=2
    end block initialize_timetracker


    ! Initialize timers
    initialize_timers: block
      wt_total%time=0.0_WP; wt_total%percent=0.0_WP
      wt_vel%time=0.0_WP;   wt_vel%percent=0.0_WP
      wt_pres%time=0.0_WP;  wt_pres%percent=0.0_WP
      wt_lpt%time=0.0_WP;   wt_lpt%percent=0.0_WP
      wt_sgs%time=0.0_WP;   wt_sgs%percent=0.0_WP
      wt_rest%time=0.0_WP;  wt_rest%percent=0.0_WP
    end block initialize_timers


    ! Create a low Mach flow solver with bconds
    create_flow_solver: block
      use hypre_uns_class, only: gmres_amg  
      use hypre_str_class, only: pcg_pfmg
      use lowmach_class,   only: dirichlet,clipped_neumann,slip
      ! Create flow solver
      fs=lowmach(cfg=cfg,name='Variable density low Mach NS')
      ! Define boundary conditions
      call fs%add_bcond(name='left',type=dirichlet,locator=left_of_domain,face='x',dir=-1,canCorrect=.false.)
      call fs%add_bcond(name='right',type=dirichlet,locator=right_of_domain,face='x',dir=+1,canCorrect=.false.)
      call fs%add_bcond(name='bottom',type=dirichlet,locator=bottom_of_domain,face='y',dir=-1,canCorrect=.false.)
      call fs%add_bcond(name='top',type=slip,locator=top_of_domain,face='y',dir=+1,canCorrect=.true. )
      ! Assign constant density
      call param_read('Density',rho); fs%rho=rho
      ! Assign constant viscosity
      call param_read('Dynamic viscosity',visc); fs%visc=visc
      ! Assign acceleration of gravity
      call param_read('Gravity',fs%gravity)
      ! Configure pressure solver
      ps=hypre_uns(cfg=cfg,name='Pressure',method=gmres_amg,nst=7)
      call param_read('Pressure iteration',ps%maxit)
      call param_read('Pressure tolerance',ps%rcvg)
      ! Configure implicit velocity solver
      vs=hypre_str(cfg=cfg,name='Velocity',method=pcg_pfmg,nst=7)
      call param_read('Implicit iteration',vs%maxit)
      call param_read('Implicit tolerance',vs%rcvg)
      ! Setup the solver
      call fs%setup(pressure_solver=ps,implicit_solver=vs)
    end block create_flow_solver


    ! Allocate work arrays
    allocate_work_arrays: block
      allocate(SR      (1:6,cfg%imino_:cfg%imaxo_,cfg%jmino_:cfg%jmaxo_,cfg%kmino_:cfg%kmaxo_)) 
      allocate(dRHOdt  (cfg%imino_:cfg%imaxo_,cfg%jmino_:cfg%jmaxo_,cfg%kmino_:cfg%kmaxo_))
      allocate(resU    (cfg%imino_:cfg%imaxo_,cfg%jmino_:cfg%jmaxo_,cfg%kmino_:cfg%kmaxo_))
      allocate(resV    (cfg%imino_:cfg%imaxo_,cfg%jmino_:cfg%jmaxo_,cfg%kmino_:cfg%kmaxo_))
      allocate(resW    (cfg%imino_:cfg%imaxo_,cfg%jmino_:cfg%jmaxo_,cfg%kmino_:cfg%kmaxo_))
      allocate(srcUlp  (cfg%imino_:cfg%imaxo_,cfg%jmino_:cfg%jmaxo_,cfg%kmino_:cfg%kmaxo_))
      allocate(srcVlp  (cfg%imino_:cfg%imaxo_,cfg%jmino_:cfg%jmaxo_,cfg%kmino_:cfg%kmaxo_))
      allocate(srcWlp  (cfg%imino_:cfg%imaxo_,cfg%jmino_:cfg%jmaxo_,cfg%kmino_:cfg%kmaxo_))
      allocate(Ui      (cfg%imino_:cfg%imaxo_,cfg%jmino_:cfg%jmaxo_,cfg%kmino_:cfg%kmaxo_))
      allocate(Vi      (cfg%imino_:cfg%imaxo_,cfg%jmino_:cfg%jmaxo_,cfg%kmino_:cfg%kmaxo_))
      allocate(Wi      (cfg%imino_:cfg%imaxo_,cfg%jmino_:cfg%jmaxo_,cfg%kmino_:cfg%kmaxo_))
      allocate(rho0    (cfg%imino_:cfg%imaxo_,cfg%jmino_:cfg%jmaxo_,cfg%kmino_:cfg%kmaxo_))
      allocate(tmp1    (cfg%imino_:cfg%imaxo_,cfg%jmino_:cfg%jmaxo_,cfg%kmino_:cfg%kmaxo_))
      allocate(tmp2    (cfg%imino_:cfg%imaxo_,cfg%jmino_:cfg%jmaxo_,cfg%kmino_:cfg%kmaxo_))
      allocate(tmp3    (cfg%imino_:cfg%imaxo_,cfg%jmino_:cfg%jmaxo_,cfg%kmino_:cfg%kmaxo_))
    end block allocate_work_arrays


    ! Initialize our LPT solver
    initialize_lpt: block
      use random, only: random_uniform
      use mathtools, only: Pi
      real(WP) :: dp,Wbed,VFavg,Volp
      integer :: i,j,np
      logical :: overlap
      ! Create solver
      lp=lpt(cfg=cfg,name='LPT')
      ! Get drag model from the inpit
      call param_read('Drag model',lp%drag_model,default='Tenneti')
      ! Get particle density from the input
      call param_read('Particle density',lp%rho)
      ! Get particle diameter from the input
      call param_read('Particle diameter',dp)
      ! Set filter scale to 3.5*dx
      lp%filter_width=3.5_WP*cfg%min_meshsize
      ! Maximum timestep size used for particles
      call param_read('Particle timestep size',lp_dt_max,default=huge(1.0_WP))
      lp_dt=lp_dt_max

      ! Root process initializes particles uniformly
      call param_read('Bed width',Wbed)
      call param_read('Particle volume fraction',VFavg)
      if (lp%cfg%amRoot) then
         ! Particle volume
         Volp = Pi/6.0_WP*dp**3
         ! Get number of particles
         np = Wbed*lp%cfg%yL*lp%cfg%zL*VFavg/Volp
         call lp%resize(np)
         ! Distribute particles
         do i=1,np
            ! Give position (avoid overlap)
            overlap=.true.
            do while(overlap)
               lp%p(i)%pos=[random_uniform(0.5_WP*dp,Wbed),&
                    &            random_uniform(lp%cfg%y(lp%cfg%jmin)+0.5_WP*dp,lp%cfg%y(lp%cfg%jmax+1)-0.5_WP*dp),&
                    &            random_uniform(lp%cfg%z(lp%cfg%kmin),lp%cfg%z(lp%cfg%kmax+1))]
               if (lp%cfg%nz.eq.1) lp%p(i)%pos(3)=lp%cfg%zm(lp%cfg%kmin_)
               overlap=.false.
               check: do j=1,i-1
                  if (sqrt(sum((lp%p(i)%pos-lp%p(j)%pos)**2)).lt.0.5_WP*(lp%p(i)%d+lp%p(j)%d)) then
                     overlap=.true.
                     exit check
                  end if
               end do check
            end do
            !print *, real(i,WP)/real(np,WP)*100.0_WP,'%'
            ! Give id
            lp%p(i)%id=int(i,8)
            ! Set the diameter
            lp%p(i)%d=dp
            ! Set the temperature
            lp%p(i)%T=298.15_WP
            ! Give zero velocity
            lp%p(i)%vel=0.0_WP
            ! Give zero collision force
            lp%p(i)%Acol=0.0_WP
            lp%p(i)%Tcol=0.0_WP
            ! Give zero dt
            lp%p(i)%dt=0.0_WP
            ! Locate the particle on the mesh
            lp%p(i)%ind=lp%cfg%get_ijk_global(lp%p(i)%pos,[lp%cfg%imin,lp%cfg%jmin,lp%cfg%kmin])
            ! Activate the particle
            lp%p(i)%flag=0
         end do
      end if
      call lp%sync()

      ! Get initial particle volume fraction
      call lp%update_VF()
      ! Set collision timescale
      call param_read('Collision timescale',lp%tau_col,default=15.0_WP*time%dt)
      ! Set coefficient of restitution
      call param_read('Coefficient of restitution',lp%e_n)
      call param_read('Wall restitution',lp%e_w,default=lp%e_n)
      call param_read('Friction coefficient',lp%mu_f,default=0.0_WP)
      ! Set gravity
      call param_read('Gravity',lp%gravity)
      if (lp%cfg%amRoot) then
         print*,"===== Particle Setup Description ====="
         print*,'Number of particles', np
         print*,'Mean volume fraction',VFavg
      end if
    end block initialize_lpt


    ! Create partmesh object for Lagrangian particle output
    create_pmesh: block
      integer :: i
      pmesh=partmesh(nvar=1,nvec=1,name='lpt')
      pmesh%varname(1)='diameter'
      pmesh%vecname(1)='velocity'
      call lp%update_partmesh(pmesh)
      do i=1,lp%np_
         pmesh%var(1,i)=lp%p(i)%d
         pmesh%vec(:,1,i)=lp%p(i)%vel
      end do
    end block create_pmesh


    ! Initialize our velocity field
    initialize_velocity: block
      use lowmach_class, only: bcond
      type(bcond), pointer :: mybc
      integer :: n,i,j,k
      ! Zero initial field
      fs%U=0.0_WP; fs%V=0.0_WP; fs%W=0.0_WP
      ! Set no-slip walls
      call fs%get_bcond('left',mybc)
      do n=1,mybc%itr%no_
         i=mybc%itr%map(1,n); j=mybc%itr%map(2,n); k=mybc%itr%map(3,n)
         fs%U(i,j,k)=0.0_WP; fs%V(i,j,k)=0.0_WP; fs%W(i,j,k)=0.0_WP
      end do
      call fs%get_bcond('right',mybc)
      do n=1,mybc%itr%no_
         i=mybc%itr%map(1,n); j=mybc%itr%map(2,n); k=mybc%itr%map(3,n)
         fs%U(i,j,k)=0.0_WP; fs%V(i,j,k)=0.0_WP; fs%W(i,j,k)=0.0_WP
      end do
      call fs%get_bcond('bottom',mybc)
      do n=1,mybc%itr%no_
         i=mybc%itr%map(1,n); j=mybc%itr%map(2,n); k=mybc%itr%map(3,n)
         fs%U(i,j,k)=0.0_WP; fs%V(i,j,k)=0.0_WP; fs%W(i,j,k)=0.0_WP
      end do
      ! Set density from particle volume fraction and store initial density
      fs%rho=rho*(1.0_WP-lp%VF)
      rho0=rho
      ! Form momentum
      call fs%rho_multiply
      ! Apply all other boundary conditions
      call fs%apply_bcond(time%t,time%dt)
      call fs%interp_vel(Ui,Vi,Wi)
      call fs%get_div(drhodt=dRHOdt)
      ! Compute MFR through all boundary conditions
      call fs%get_mfr()
    end block initialize_velocity


    ! Create an LES model
    create_sgs: block
      sgs=sgsmodel(cfg=fs%cfg,umask=fs%umask,vmask=fs%vmask,wmask=fs%wmask)
    end block create_sgs

    
    ! Add Ensight output
    create_ensight: block
      ! Create Ensight output from cfg
      ens_out=ensight(cfg=cfg,name='turbidity')
      ! Create event for Ensight output
      ens_evt=event(time=time,name='Ensight output')
      call param_read('Ensight output period',ens_evt%tper)
      ! Add variables to output
      call ens_out%add_particle('particles',pmesh)
      call ens_out%add_vector('velocity',Ui,Vi,Wi)
      call ens_out%add_scalar('epsp',lp%VF)
      call ens_out%add_scalar('PTKE',lp%ptke)
      call ens_out%add_scalar('pressure',fs%P)
      call ens_out%add_scalar('visc_sgs',sgs%visc)
      ! Output to ensight
      if (ens_evt%occurs()) call ens_out%write_data(time%t)
    end block create_ensight

    
    ! Create monitor filea
    create_monitor: block
      ! Prepare some info about fields
      real(WP) :: cfl
      call lp%get_cfl(time%dt,cflc=time%cfl)
      call fs%get_cfl(time%dt,cfl,cfl); time%cfl=max(time%cfl,cfl)
      call fs%get_max()
      call lp%get_max()
      ! Create simulation monitor
      mfile=monitor(fs%cfg%amRoot,'simulation')
      call mfile%add_column(time%n,'Timestep number')
      call mfile%add_column(time%t,'Time')
      call mfile%add_column(time%dt,'Timestep size')
      call mfile%add_column(time%cfl,'Maximum CFL')
      call mfile%add_column(fs%Umax,'Umax')
      call mfile%add_column(fs%Vmax,'Vmax')
      call mfile%add_column(fs%Wmax,'Wmax')
      call mfile%add_column(fs%Pmax,'Pmax')
      call mfile%add_column(fs%divmax,'Maximum divergence')
      call mfile%add_column(fs%psolv%it,'Pressure iteration')
      call mfile%add_column(fs%psolv%rerr,'Pressure error')
      call mfile%write()
      ! Create CFL monitor
      cflfile=monitor(fs%cfg%amRoot,'cfl')
      call cflfile%add_column(time%n,'Timestep number')
      call cflfile%add_column(time%t,'Time')
      call cflfile%add_column(fs%CFLc_x,'Convective xCFL')
      call cflfile%add_column(fs%CFLc_y,'Convective yCFL')
      call cflfile%add_column(fs%CFLc_z,'Convective zCFL')
      call cflfile%add_column(fs%CFLv_x,'Viscous xCFL')
      call cflfile%add_column(fs%CFLv_y,'Viscous yCFL')
      call cflfile%add_column(fs%CFLv_z,'Viscous zCFL')
      call cflfile%add_column(lp%CFL_col,'Collision CFL')
      call cflfile%write()
      ! Create LPT monitor
      lptfile=monitor(amroot=lp%cfg%amRoot,name='lpt')
      call lptfile%add_column(time%n,'Timestep number')
      call lptfile%add_column(time%t,'Time')
      call lptfile%add_column(lp_dt,'Particle dt')
      call lptfile%add_column(lp%VFmean,'VFp mean')
      call lptfile%add_column(lp%VFmax,'VFp max')
      call lptfile%add_column(lp%np,'Particle number')
      call lptfile%add_column(lp%Umin,'Particle Umin')
      call lptfile%add_column(lp%Umax,'Particle Umax')
      call lptfile%add_column(lp%Vmin,'Particle Vmin')
      call lptfile%add_column(lp%Vmax,'Particle Vmax')
      call lptfile%add_column(lp%Wmin,'Particle Wmin')
      call lptfile%add_column(lp%Wmax,'Particle Wmax')
      call lptfile%add_column(lp%dmin,'Particle dmin')
      call lptfile%add_column(lp%dmax,'Particle dmax')
      call lptfile%write()
      ! Create timing monitor
      tfile=monitor(amroot=fs%cfg%amRoot,name='timing')
      call tfile%add_column(time%n,'Timestep number')
      call tfile%add_column(time%t,'Time')
      call tfile%add_column(wt_total%time,'Total [s]')
      call tfile%add_column(wt_vel%time,'Velocity [s]')
      call tfile%add_column(wt_vel%percent,'Velocity [%]')
      call tfile%add_column(wt_pres%time,'Pressure [s]')
      call tfile%add_column(wt_pres%percent,'Pressure [%]')
      call tfile%add_column(wt_lpt%time,'LPT [s]')
      call tfile%add_column(wt_lpt%percent,'LPT [%]')
      call tfile%add_column(wt_sgs%time,'SGS [s]')
      call tfile%add_column(wt_sgs%percent,'SGS [%]')
      call tfile%add_column(wt_rest%time,'Rest [s]')
      call tfile%add_column(wt_rest%percent,'Rest [%]')
      call tfile%write()
    end block create_monitor

    ! Create a specialized post-processing file
    create_postproc: block
      ! Create event for data postprocessing
      ppevt=event(time=time,name='Postproc output')
      call param_read('Postproc output period',ppevt%tper)
      ! Perform the output
      if (ppevt%occurs()) call postproc_vel()
    end block create_postproc
    
  end subroutine simulation_init


  !> Perform an NGA2 simulation
  subroutine simulation_run
    use mathtools, only: twoPi
    use parallel, only: parallel_time
    implicit none
    real(WP) :: cfl

    ! Perform time integration
    do while (.not.time%done())

       ! Initial wallclock time
       wt_total%time_in=parallel_time()

       ! Increment time
       call lp%get_cfl(time%dt,cflc=time%cfl)
       call fs%get_cfl(time%dt,cfl); time%cfl=max(time%cfl,cfl)
       call time%adjust_dt()
       call time%increment()

       ! Remember old density, velocity, and momentum
       fs%rhoold=fs%rho
       fs%Uold=fs%U; fs%rhoUold=fs%rhoU
       fs%Vold=fs%V; fs%rhoVold=fs%rhoV
       fs%Wold=fs%W; fs%rhoWold=fs%rhoW

       wt_lpt%time_in=parallel_time()
       ! Particle update
       lpt: block
         real(WP) :: dt_done,mydt
         ! Get fluid stress
         call fs%get_div_stress(resU,resV,resW)
         ! Get vorticity
         call fs%get_vorticity(SR(1:3,:,:,:))
         ! Zero-out LPT source terms
         srcUlp=0.0_WP; srcVlp=0.0_WP; srcWlp=0.0_WP
         ! Sub-iteratore
         call lp%get_cfl(lp_dt,cflc=cfl,cfl=cfl)
         if (cfl.gt.0.0_WP) lp_dt=min(lp_dt*time%cflmax/cfl,lp_dt_max)
         dt_done=0.0_WP
         do while (dt_done.lt.time%dtmid)
            ! Decide the timestep size
            mydt=min(lp_dt,time%dtmid-dt_done)
            ! Collide and advance particles
            call lp%collide(dt=mydt)
            call lp%advance(dt=mydt,U=fs%U,V=fs%V,W=fs%W,rho=rho0,visc=fs%visc,stress_x=resU,stress_y=resV,stress_z=resW,&
                 srcU=tmp1,srcV=tmp2,srcW=tmp3)
            srcUlp=srcUlp+tmp1
            srcVlp=srcVlp+tmp2
            srcWlp=srcWlp+tmp3
            ! Increment
            dt_done=dt_done+mydt
         end do
         ! Compute PTKE and store source terms
         call lp%get_ptke(dt=time%dtmid,Ui=Ui,Vi=Vi,Wi=Wi,visc=fs%visc,rho=fs%rho,srcU=tmp1,srcV=tmp2,srcW=tmp3)
         srcUlp=srcUlp+tmp1
         srcVlp=srcVlp+tmp2
         srcWlp=srcWlp+tmp3
         ! Update density based on particle volume fraction
         fs%rho=rho*(1.0_WP-lp%VF)
         dRHOdt=(fs%RHO-fs%RHOold)/time%dtmid
       end block lpt
       wt_lpt%time=wt_lpt%time+parallel_time()-wt_lpt%time_in

       ! Turbulence modeling
       wt_sgs%time_in=parallel_time()
       sgs_modeling: block
         use sgsmodel_class, only: dynamic_smag
         call fs%get_strainrate(SR)
         call sgs%get_visc(type=dynamic_smag,dt=time%dtold,rho=rho0,Ui=Ui,Vi=Vi,Wi=Wi,SR=SR)
         fs%visc=visc+sgs%visc
       end block sgs_modeling
       wt_sgs%time=wt_sgs%time+parallel_time()-wt_sgs%time_in

       ! Perform sub-iterations
       do while (time%it.le.time%itmax)

          wt_vel%time_in=parallel_time()

          ! Build mid-time velocity and momentum
          fs%U=0.5_WP*(fs%U+fs%Uold); fs%rhoU=0.5_WP*(fs%rhoU+fs%rhoUold)
          fs%V=0.5_WP*(fs%V+fs%Vold); fs%rhoV=0.5_WP*(fs%rhoV+fs%rhoVold)
          fs%W=0.5_WP*(fs%W+fs%Wold); fs%rhoW=0.5_WP*(fs%rhoW+fs%rhoWold)

          ! Explicit calculation of drho*u/dt from NS
          call fs%get_dmomdt(resU,resV,resW)

          ! Add momentum source terms
          call fs%addsrc_gravity(resU,resV,resW)

          ! Assemble explicit residual
          resU=time%dtmid*resU-(2.0_WP*fs%rhoU-2.0_WP*fs%rhoUold)
          resV=time%dtmid*resV-(2.0_WP*fs%rhoV-2.0_WP*fs%rhoVold)
          resW=time%dtmid*resW-(2.0_WP*fs%rhoW-2.0_WP*fs%rhoWold)

          ! Add momentum source term from lpt
          add_lpt_src: block
            integer :: i,j,k
            do k=fs%cfg%kmin_,fs%cfg%kmax_
               do j=fs%cfg%jmin_,fs%cfg%jmax_
                  do i=fs%cfg%imin_,fs%cfg%imax_
                     resU(i,j,k)=resU(i,j,k)+sum(fs%itpr_x(:,i,j,k)*srcUlp(i-1:i,j,k))
                     resV(i,j,k)=resV(i,j,k)+sum(fs%itpr_y(:,i,j,k)*srcVlp(i,j-1:j,k))
                     resW(i,j,k)=resW(i,j,k)+sum(fs%itpr_z(:,i,j,k)*srcWlp(i,j,k-1:k))
                  end do
               end do
            end do
          end block add_lpt_src

          ! Form implicit residuals
          call fs%solve_implicit(time%dtmid,resU,resV,resW)

          ! Apply these residuals
          fs%U=2.0_WP*fs%U-fs%Uold+resU
          fs%V=2.0_WP*fs%V-fs%Vold+resV
          fs%W=2.0_WP*fs%W-fs%Wold+resW
          
          ! Apply other boundary conditions and update momentum
          call fs%apply_bcond(time%tmid,time%dtmid)
          call fs%rho_multiply()
          call fs%apply_bcond(time%tmid,time%dtmid)

          ! Reset Dirichlet BCs
          dirichlet_velocity: block
            use lowmach_class, only: bcond
            type(bcond), pointer :: mybc
            integer :: n,i,j,k
            call fs%get_bcond('bottom',mybc)
            do n=1,mybc%itr%no_
               i=mybc%itr%map(1,n); j=mybc%itr%map(2,n); k=mybc%itr%map(3,n)
               fs%rhoU(i,j,k)=0.0_WP; fs%rhoV(i,j,k)=0.0_WP; fs%rhoW(i,j,k)=0.0_WP
               fs%U(i,j,k)=0.0_WP; fs%V(i,j,k)=0.0_WP; fs%W(i,j,k)=0.0_WP
            end do
            call fs%get_bcond('left',mybc)
            do n=1,mybc%itr%no_
               i=mybc%itr%map(1,n); j=mybc%itr%map(2,n); k=mybc%itr%map(3,n)
               fs%rhoU(i,j,k)=0.0_WP; fs%rhoV(i,j,k)=0.0_WP; fs%rhoW(i,j,k)=0.0_WP
               fs%U(i,j,k)=0.0_WP; fs%V(i,j,k)=0.0_WP; fs%W(i,j,k)=0.0_WP
            end do
            call fs%get_bcond('right',mybc)
            do n=1,mybc%itr%no_
               i=mybc%itr%map(1,n); j=mybc%itr%map(2,n); k=mybc%itr%map(3,n)
               fs%rhoU(i,j,k)=0.0_WP; fs%rhoV(i,j,k)=0.0_WP; fs%rhoW(i,j,k)=0.0_WP
               fs%U(i,j,k)=0.0_WP; fs%V(i,j,k)=0.0_WP; fs%W(i,j,k)=0.0_WP
            end do
          end block dirichlet_velocity

          wt_vel%time=wt_vel%time+parallel_time()-wt_vel%time_in

          ! Solve Poisson equation
          wt_pres%time_in=parallel_time()
          call fs%correct_mfr(drhodt=dRHOdt)
          call fs%get_div(drhodt=dRHOdt)
          fs%psolv%rhs=-fs%cfg%vol*fs%div/time%dtmid
          fs%psolv%sol=0.0_WP
          call fs%psolv%solve()
          call fs%shift_p(fs%psolv%sol)

          ! Correct momentum and rebuild velocity
          call fs%get_pgrad(fs%psolv%sol,resU,resV,resW)
          fs%P=fs%P+fs%psolv%sol
          fs%rhoU=fs%rhoU-time%dtmid*resU
          fs%rhoV=fs%rhoV-time%dtmid*resV
          fs%rhoW=fs%rhoW-time%dtmid*resW
          call fs%rho_divide
          wt_pres%time=wt_pres%time+parallel_time()-wt_pres%time_in

          ! Increment sub-iteration counter
          time%it=time%it+1

       end do

       ! Recompute interpolated velocity and divergence
       wt_vel%time_in=parallel_time()
       call fs%interp_vel(Ui,Vi,Wi)
       call fs%get_div(drhodt=dRHOdt)
       wt_vel%time=wt_vel%time+parallel_time()-wt_vel%time_in

       ! Output to ensight
       if (ens_evt%occurs()) then
          update_pmesh: block
            integer :: i
            call lp%update_partmesh(pmesh)
            do i=1,lp%np_
               pmesh%var(1,i)=lp%p(i)%d
               pmesh%vec(:,1,i)=lp%p(i)%vel
            end do
          end block update_pmesh
          call ens_out%write_data(time%t)
       end if

       ! Perform and output monitoring
       call fs%get_max()
       call lp%get_max()
       call mfile%write()
       call cflfile%write()
       call lptfile%write()

       ! Monitor timing
       wt_total%time=parallel_time()-wt_total%time_in
       wt_vel%percent=wt_vel%time/wt_total%time*100.0_WP
       wt_pres%percent=wt_pres%time/wt_total%time*100.0_WP
       wt_lpt%percent=wt_lpt%time/wt_total%time*100.0_WP
       wt_sgs%percent=wt_sgs%time/wt_total%time*100.0_WP
       wt_rest%time=wt_total%time-wt_vel%time-wt_pres%time-wt_lpt%time-wt_sgs%time
       wt_rest%percent=wt_rest%time/wt_total%time*100.0_WP
       call tfile%write()
       wt_total%time=0.0_WP; wt_total%percent=0.0_WP
       wt_vel%time=0.0_WP;   wt_vel%percent=0.0_WP
       wt_pres%time=0.0_WP;  wt_pres%percent=0.0_WP
       wt_lpt%time=0.0_WP;   wt_lpt%percent=0.0_WP
       wt_sgs%time=0.0_WP;   wt_sgs%percent=0.0_WP
       wt_rest%time=0.0_WP;  wt_rest%percent=0.0_WP

       ! Specialized post-processing
       if (ppevt%occurs()) call postproc_vel()

    end do

  end subroutine simulation_run


  !> Finalize the NGA2 simulation
  subroutine simulation_final
    implicit none

    ! Get rid of all objects - need destructors
    ! monitor
    ! ensight
    ! bcond
    ! timetracker

    ! Deallocate work arrays
    deallocate(resU,resV,resW,srcUlp,srcVlp,srcWlp,Ui,Vi,Wi,dRHOdt,SR,tmp1,tmp2,tmp3)

  end subroutine simulation_final

end module simulation
